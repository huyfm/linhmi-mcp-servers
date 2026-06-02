#!/usr/bin/env bash
# Register the remote read-only VNPay Atlassian MCP server (Azure Container Apps,
# streamable-http over HTTPS, GitHub OAuth) with Claude Code.
#
# The server is now a remote HTTP endpoint, not a local Docker/stdio container,
# so registration is a one-liner: Claude Code dials the URL and runs the GitHub
# OAuth flow in your browser on first use. For Claude Desktop, use a native
# custom connector instead -- see docs/atlassian-remote.md.
#
# Usage:
#   bash scripts/setup-jira-mcp.sh https://<your-container-app-fqdn>/mcp
#   bash scripts/setup-jira-mcp.sh                 # reads MCP_URL from env or .env
#   bash scripts/setup-jira-mcp.sh --scope project https://.../mcp
#
# It never disables the deployment's read-only layers; it only points a client
# at the already-deployed, read-only server.

set -euo pipefail

SERVER_NAME="vnpay-atlassian"
SCOPE="user"

die()  { echo "Error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- parse args: optional --scope <s>, optional URL ---
URL_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *)  URL_ARG="$1"; shift ;;
  esac
done

# --- resolve the endpoint URL: arg > $MCP_URL > PUBLIC_BASE_URL in .env ---
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${URL_ARG:-${MCP_URL:-}}"
if [ -z "$URL" ] && [ -f "$REPO/.env" ]; then
  BASE="$(grep -E '^PUBLIC_BASE_URL=' "$REPO/.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  [ -n "$BASE" ] && case "$BASE" in *replace-with-your*) ;; *) URL="${BASE%/}/mcp" ;; esac
fi
[ -n "$URL" ] || die "No endpoint URL. Pass it: bash scripts/setup-jira-mcp.sh https://<fqdn>/mcp"
case "$URL" in
  https://*) ;;
  *) die "Endpoint must be an https:// URL (got: $URL)" ;;
esac
note "Endpoint: $URL"
note "Scope:    $SCOPE"

# --- need the Claude Code CLI ---
command -v claude >/dev/null 2>&1 || die "'claude' CLI not found. Install Claude Code and re-run."

# --- (re)register, so re-runs don't fail on a duplicate name ---
claude mcp remove "$SERVER_NAME" >/dev/null 2>&1 || true
claude mcp add --scope "$SCOPE" --transport http "$SERVER_NAME" "$URL" \
  || die "claude mcp add failed."

note "Registered '$SERVER_NAME' with Claude Code."
echo
echo "Next steps:"
echo "  1. In Claude Code run /mcp (or: claude mcp get $SERVER_NAME) to confirm it is listed."
echo "  2. On first use, a browser opens for GitHub sign-in; authorize the OAuth app."
echo "  3. The read-only Jira/Confluence tools then appear. (Claude Desktop: see docs/atlassian-remote.md.)"
