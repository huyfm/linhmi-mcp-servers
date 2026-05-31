#!/usr/bin/env bash
# Configure Claude Desktop (Windows) to launch the read-only VNPay Atlassian
# MCP server that runs as a Docker container inside WSL2.
#
# Run this INSIDE WSL2 (the same distro where Docker works):
#   bash scripts/setup-claude-desktop.sh                      # Claude Desktop only
#   bash scripts/setup-claude-desktop.sh --with-claude-code   # also register Claude Code (WSL2)
#   bash scripts/setup-claude-desktop.sh /path/to/repo        # explicit repo path
#
# Claude Desktop is a Windows app and cannot see WSL's docker directly, so it is
# bridged through wsl.exe. This script verifies the WSL side, pulls the image,
# and merges a server entry into the Windows claude_desktop_config.json
# (preserving any existing servers and backing up the old file).
#
# With --with-claude-code it ALSO registers the server with Claude Code running
# in WSL2, which talks to docker directly (no wsl.exe bridge needed).
#
# It never disables the repo's read-only layers.

set -euo pipefail

SERVER_NAME="vnpay-atlassian"

die()  { echo "Error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- parse args: optional --with-claude-code flag + optional repo path ---
WITH_CLAUDE_CODE=0
REPO_ARG=""
for arg in "$@"; do
  case "$arg" in
    --with-claude-code) WITH_CLAUDE_CODE=1 ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) die "Unknown option: $arg" ;;
    *)  REPO_ARG="$arg" ;;
  esac
done

# --- must run inside WSL2 ---
if [ -z "${WSL_DISTRO_NAME:-}" ]; then
  die "Run this inside WSL2 (could not read \$WSL_DISTRO_NAME). Open your distro and re-run."
fi
DISTRO="$WSL_DISTRO_NAME"
note "WSL distro: $DISTRO"

# --- locate the repo (the directory holding docker-compose.yml) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_repo() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/docker-compose.yml" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
if [ -n "$REPO_ARG" ]; then
  REPO="$(cd "$REPO_ARG" 2>/dev/null && pwd)" || die "Repo path not found: $REPO_ARG"
  [ -f "$REPO/docker-compose.yml" ] || die "No docker-compose.yml in $REPO"
else
  REPO="$(find_repo "$SCRIPT_DIR")" || REPO="$(find_repo "$PWD")" || \
    die "Could not find docker-compose.yml. Pass the repo path: bash setup-claude-desktop.sh /path/to/repo"
fi
COMPOSE="$REPO/docker-compose.yml"
note "Repo: $REPO"

# --- docker available, daemon up, compose plugin present ---
DOCKER="$(command -v docker || true)"
[ -n "$DOCKER" ] || die "docker not found in '$DISTRO'. Enable Docker Desktop WSL integration for this distro."
docker info >/dev/null 2>&1 || die "Docker daemon not reachable. Start Docker Desktop and re-run."
docker compose version >/dev/null 2>&1 || die "The 'docker compose' plugin is missing. Install/enable Compose v2."
note "docker: $DOCKER"

# --- .env present and filled in ---
if [ ! -f "$REPO/.env" ]; then
  if [ -f "$REPO/.env.example" ]; then
    cp "$REPO/.env.example" "$REPO/.env"
    echo "Warning: created $REPO/.env from .env.example -- edit it with real PATs before use." >&2
  else
    die "No .env or .env.example in $REPO."
  fi
fi
if grep -q 'replace-with-your' "$REPO/.env" 2>/dev/null; then
  echo "Warning: $REPO/.env still has placeholder token(s); the server will fail to authenticate until you edit it." >&2
fi

# --- pull the pinned image ---
note "Pulling MCP image (docker compose pull)..."
docker compose -f "$COMPOSE" pull

# --- choose the wsl.exe invocation form Claude Desktop will use ---
# Prefer calling the docker binary directly (cleanest stdio for the JSON-RPC
# stream). Fall back to a login shell only if the compose plugin resolves via
# PATH but not when docker is called by absolute path.
if "$DOCKER" compose version >/dev/null 2>&1; then
  ARGS=(-d "$DISTRO" -- "$DOCKER" compose -f "$COMPOSE" run --rm -T atlassian-mcp)
else
  ARGS=(-d "$DISTRO" -- bash -lc "exec docker compose -f '$COMPOSE' run --rm -T atlassian-mcp")
fi

# --- find the Windows Claude config dir via %APPDATA% ---
APPDATA_WIN="$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r' || true)"
[ -n "$APPDATA_WIN" ] || die "Could not read Windows %APPDATA% (is WSL interop enabled?)."
APPDATA_WSL="$(wslpath -u "$APPDATA_WIN")" || die "wslpath failed on: $APPDATA_WIN"
CONFIG_DIR="$APPDATA_WSL/Claude"
CONFIG="$CONFIG_DIR/claude_desktop_config.json"
mkdir -p "$CONFIG_DIR"

# --- back up any existing config ---
if [ -f "$CONFIG" ]; then
  BACKUP="$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  note "Backed up existing config to: $BACKUP"
fi

# --- merge the server entry, preserving any other servers ---
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CONFIG" "$SERVER_NAME" "${ARGS[@]}" <<'PY'
import json, sys
path, name, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        cfg = {}
except (FileNotFoundError, ValueError):
    cfg = {}
cfg.setdefault("mcpServers", {})
cfg["mcpServers"][name] = {"command": "wsl.exe", "args": args}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
elif command -v jq >/dev/null 2>&1; then
  base='{}'
  [ -s "$CONFIG" ] && base="$(cat "$CONFIG")"
  printf '%s' "$base" | jq \
    --arg name "$SERVER_NAME" \
    '.mcpServers[$name] = {command: "wsl.exe", args: $ARGS.positional}' \
    --args "${ARGS[@]}" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
else
  die "Need python3 or jq to safely edit the JSON config. Install one (e.g. 'sudo apt install -y python3') and re-run."
fi

note "Wrote $CONFIG"
echo
echo "Server '$SERVER_NAME' will launch via:"
echo "  wsl.exe ${ARGS[*]}"

# --- optionally register with Claude Code (runs in WSL2, talks to docker directly) ---
if [ "$WITH_CLAUDE_CODE" -eq 1 ]; then
  echo
  if ! command -v claude >/dev/null 2>&1; then
    die "--with-claude-code given but 'claude' CLI not found in this WSL distro. Install Claude Code and re-run, or drop the flag."
  fi
  # Remove any prior registration so re-runs don't fail on a duplicate name.
  claude mcp remove "$SERVER_NAME" >/dev/null 2>&1 || true
  claude mcp add "$SERVER_NAME" -- \
    docker compose -f "$COMPOSE" run --rm -T atlassian-mcp \
    || die "claude mcp add failed."
  note "Registered '$SERVER_NAME' with Claude Code (WSL2)."
fi

echo
echo "Next steps:"
echo "  1. Make sure Docker Desktop is running."
echo "  2. Fully quit Claude Desktop from the system tray (not just the window), then reopen it."
echo "  3. The '$SERVER_NAME' tools should appear. If the server is missing, open"
echo "     Claude Desktop's logs and confirm the command above runs in your WSL shell."
if [ "$WITH_CLAUDE_CODE" -eq 1 ]; then
  echo "  4. In Claude Code, run /mcp to confirm '$SERVER_NAME' is connected."
fi
