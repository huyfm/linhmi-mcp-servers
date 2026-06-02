#!/usr/bin/env bash
# Install the remote Google Chat MCP server into Claude Desktop (Windows),
# bridged through `mcp-remote` (Claude Desktop is stdio-only and cannot dial a
# remote HTTP MCP URL directly).
#
# Run this INSIDE WSL2. It reuses the non-secret config from your Claude Code
# registration (~/.claude.json: url, x-goog-user-project, clientId, callbackPort),
# writes the OAuth client-info file to the Windows side, and merges a
# `google-chat` entry into the Windows claude_desktop_config.json (preserving any
# other servers and backing up the old file). The client SECRET is never read
# from the repo -- supply it at runtime.
#
# Usage:
#   export GOOGLE_CHAT_CLIENT_SECRET='GOCSPX-...'
#   bash scripts/setup-google-chat-desktop.sh
#   bash scripts/setup-google-chat-desktop.sh --client-info-file ~/secrets/gc.json
#
# Overridable via env: GOOGLE_CHAT_URL, GOOGLE_CHAT_PROJECT,
#   GOOGLE_CHAT_CLIENT_ID, GOOGLE_CHAT_CLIENT_SECRET, GOOGLE_CHAT_CALLBACK_PORT.

set -euo pipefail

SERVER_NAME="google-chat"
URL_FALLBACK="https://chatmcp.googleapis.com/mcp/v1"
PORT_FALLBACK="8080"

die()  { echo "Error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- parse flags ---
CLIENT_INFO_FILE=""
CLIENT_SECRET_FLAG=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  case "$arg" in
    --client-info-file) j=$((i+1)); CLIENT_INFO_FILE="${!j:-}"; i=$j ;;
    --client-secret)    j=$((i+1)); CLIENT_SECRET_FLAG="${!j:-}"; i=$j ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $arg" ;;
  esac
done

# --- must run inside WSL2 ---
[ -n "${WSL_DISTRO_NAME:-}" ] || die "Run this inside WSL2 (could not read \$WSL_DISTRO_NAME)."
command -v python3 >/dev/null 2>&1 || die "python3 is required (used to read/write JSON safely)."

# --- pull non-secret defaults from the existing Claude Code registration ---
read_from_claude() {
  python3 - "$HOME/.claude.json" <<'PY'
import json, sys
try:
    gc = json.load(open(sys.argv[1]))["mcpServers"]["google-chat"]
except Exception:
    print("\t\t\t"); raise SystemExit
url  = gc.get("url", "")
proj = (gc.get("headers") or {}).get("x-goog-user-project", "")
oa   = gc.get("oauth") or {}
print("%s\t%s\t%s\t%s" % (url, proj, oa.get("clientId", ""), oa.get("callbackPort", "")))
PY
}
IFS=$'\t' read -r CFG_URL CFG_PROJ CFG_CID CFG_PORT < <(read_from_claude) || true

URL="${GOOGLE_CHAT_URL:-${CFG_URL:-$URL_FALLBACK}}"
PROJECT="${GOOGLE_CHAT_PROJECT:-$CFG_PROJ}"
CLIENT_ID="${GOOGLE_CHAT_CLIENT_ID:-$CFG_CID}"
PORT="${GOOGLE_CHAT_CALLBACK_PORT:-${CFG_PORT:-$PORT_FALLBACK}}"
CLIENT_SECRET="${CLIENT_SECRET_FLAG:-${GOOGLE_CHAT_CLIENT_SECRET:-}}"

# --- a client-info file (if given) is the source of truth for id+secret ---
if [ -n "$CLIENT_INFO_FILE" ]; then
  [ -f "$CLIENT_INFO_FILE" ] || die "client-info file not found: $CLIENT_INFO_FILE"
  IFS=$'\t' read -r CLIENT_ID CLIENT_SECRET < <(python3 - "$CLIENT_INFO_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("%s\t%s" % (d.get("client_id", ""), d.get("client_secret", "")))
PY
)
fi

[ -n "$PROJECT" ]   || die "No x-goog-user-project value. Set GOOGLE_CHAT_PROJECT or register google-chat in Claude Code first."
[ -n "$CLIENT_ID" ] || die "No OAuth client_id. Set GOOGLE_CHAT_CLIENT_ID or pass --client-info-file."
if [ -z "$CLIENT_SECRET" ]; then
  echo "Warning: no client secret provided. Writing client_id only; if the OAuth client requires a secret, auth will fail. Set GOOGLE_CHAT_CLIENT_SECRET or use --client-info-file." >&2
fi
note "URL: $URL"
note "Project (x-goog-user-project): $PROJECT"
note "OAuth client_id: ${CLIENT_ID%%-*}-... (callback port $PORT)"

# --- locate the Windows Claude config dir via %APPDATA% ---
APPDATA_WIN="$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r' || true)"
[ -n "$APPDATA_WIN" ] || die "Could not read Windows %APPDATA% (is WSL interop enabled?)."
APPDATA_WSL="$(wslpath -u "$APPDATA_WIN")" || die "wslpath failed on: $APPDATA_WIN"
CONFIG_DIR="$APPDATA_WSL/Claude"
CONFIG="$CONFIG_DIR/claude_desktop_config.json"
mkdir -p "$CONFIG_DIR"

# --- write the OAuth client-info file on the Windows side (referenced via @) ---
OAUTH_FILE="$CONFIG_DIR/google-chat-oauth-client.json"
python3 - "$OAUTH_FILE" "$CLIENT_ID" "$CLIENT_SECRET" <<'PY'
import json, sys
path, cid, secret = sys.argv[1], sys.argv[2], sys.argv[3]
info = {"client_id": cid}
if secret:
    info["client_secret"] = secret
with open(path, "w") as f:
    json.dump(info, f)
PY
chmod 600 "$OAUTH_FILE" 2>/dev/null || true
WIN_OAUTH="$(wslpath -w "$OAUTH_FILE")"
note "Wrote OAuth client info: $OAUTH_FILE"

# --- check for Node/npx on the WINDOWS PATH (mcp-remote runs on Windows) ---
NPX_VER="$(cmd.exe /c 'npx --version' 2>/dev/null | tr -d '\r' || true)"
if [ -z "$NPX_VER" ]; then
  echo "Warning: 'npx' not found on the Windows PATH. Install Node.js for Windows" >&2
  echo "         (e.g. 'winget install OpenJS.NodeJS.LTS') or the server will not start." >&2
else
  note "Windows npx: $NPX_VER"
fi

# --- build the Claude Desktop command (cmd /c npx ... on Windows) ---
ARGS=(/c npx -y mcp-remote "$URL" "$PORT" --transport http-only \
      --header "x-goog-user-project:$PROJECT" \
      --static-oauth-client-info "@$WIN_OAUTH")

# --- back up any existing config ---
if [ -f "$CONFIG" ]; then
  BACKUP="$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  note "Backed up existing config to: $BACKUP"
fi

# --- merge the server entry, preserving any other servers ---
python3 - "$CONFIG" "$SERVER_NAME" "cmd" "${ARGS[@]}" <<'PY'
import json, sys
path, name, command, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        cfg = {}
except (FileNotFoundError, ValueError):
    cfg = {}
cfg.setdefault("mcpServers", {})
cfg["mcpServers"][name] = {"command": command, "args": args}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

note "Wrote $CONFIG"
echo
echo "Server '$SERVER_NAME' will launch via:"
echo "  cmd ${ARGS[*]}"
echo
echo "Next steps:"
echo "  1. Ensure Node.js is installed on Windows ('npx' on the Windows PATH)."
echo "  2. Fully quit Claude Desktop from the system tray (not just the window), then reopen it."
echo "  3. On first start, approve the Google consent screen in your browser."
echo "  4. If it fails, run the command by hand in a Windows terminal to see the error:"
echo "     npx -y mcp-remote $URL $PORT --transport http-only --header x-goog-user-project:$PROJECT"
