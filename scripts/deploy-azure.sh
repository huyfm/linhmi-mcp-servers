#!/usr/bin/env bash
# Deploy the read-only Atlassian MCP server to Azure.
#
# Bicep (infra/main.bicep) provisions everything into the claude-mcp-rg resource
# group; this script does the two things Bicep can't: build + push the auth-proxy
# image to public ghcr.io, and feed your .env values (including secrets) into the
# deployment. It is idempotent -- re-run it any time; Bicep converges.
#
# Usage:
#   cp .env.example .env   # fill in URLs, PATs, GitHub OAuth creds, GHCR_USER
#   bash scripts/deploy-azure.sh
#
# First run (before you have the FQDN to register a GitHub OAuth app): leave the
# GitHub OAuth creds as placeholders. The script deploys with auth DISABLED so
# the app comes up, then prints the FQDN and the exact callback URL to register.
# Fill the real GitHub creds into .env and re-run to enable GitHub OAuth.
#
# Requires: az (logged in), docker, and either GHCR_TOKEN (a GitHub PAT with
# write:packages) in the environment or the `gh` CLI logged in.

set -euo pipefail

die()  { echo "Error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# --- load .env ---
[ -f "$REPO/.env" ] || die "No .env found. Run: cp .env.example .env  and fill it in."
set -a
# shellcheck disable=SC1091
. "$REPO/.env"
set +a

: "${AZURE_REGION:=southeastasia}"
: "${AZURE_RESOURCE_GROUP:=claude-mcp-rg}"
: "${AZURE_CONTAINERAPP:=vnpay-atlassian-mcp}"
: "${AUTH_PROXY_IMAGE:=vnpay-atlassian-auth-proxy}"
: "${AUTH_PROXY_TAG:=1}"

[ -n "${GHCR_USER:-}" ]   || die "GHCR_USER not set in .env (your GitHub username/org that owns the public package)."
[ -n "${JIRA_URL:-}" ]    || die "JIRA_URL not set in .env."
[ -n "${CONFLUENCE_URL:-}" ] || die "CONFLUENCE_URL not set in .env."
[ -n "${ENABLED_TOOLS:-}" ]  || die "ENABLED_TOOLS not set in .env."

IMAGE="ghcr.io/${GHCR_USER}/${AUTH_PROXY_IMAGE}:${AUTH_PROXY_TAG}"

# --- decide auth-disabled first pass: GitHub creds still placeholders? ---
FIRST_PASS=0
case "${GITHUB_OAUTH_CLIENT_ID:-}" in ""|*replace-with*) FIRST_PASS=1 ;; esac
case "${GITHUB_OAUTH_CLIENT_SECRET:-}" in ""|*replace-with*) FIRST_PASS=1 ;; esac
if [ "$FIRST_PASS" -eq 1 ]; then
  export AUTH_DISABLED=true
  note "GitHub OAuth creds are placeholders -> deploying with auth DISABLED (first pass to discover the FQDN)."
else
  export AUTH_DISABLED=false
fi
case "${JIRA_PERSONAL_TOKEN:-}" in *replace-with*|"") echo "Warning: JIRA_PERSONAL_TOKEN is a placeholder; Jira calls will fail until you set a real read-only PAT." >&2 ;; esac

# --- preflight: az + bicep + docker ---
command -v az >/dev/null 2>&1 || die "'az' CLI not found. Install the Azure CLI and run 'az login'."
az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"
az bicep version >/dev/null 2>&1 || az bicep install >/dev/null 2>&1 || die "Could not find/install Bicep (az bicep install)."
command -v docker >/dev/null 2>&1 || die "'docker' not found (needed to build/push the auth-proxy image)."

# --- ghcr login token ---
GHCR_TOKEN="${GHCR_TOKEN:-}"
if [ -z "$GHCR_TOKEN" ] && command -v gh >/dev/null 2>&1; then
  GHCR_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
[ -n "$GHCR_TOKEN" ] || die "No ghcr.io credentials. Set GHCR_TOKEN (GitHub PAT with write:packages) or log in with 'gh auth login'."

# --- build + push the auth-proxy image ---
# Azure Container Apps runs linux/amd64. Build for that platform explicitly so a
# build on an arm64 host (Apple Silicon) doesn't produce an arm64-only manifest
# that Azure rejects with "no child with platform linux/amd64".
note "Logging in to ghcr.io"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
note "Building + pushing $IMAGE (linux/amd64)"
docker buildx build --platform linux/amd64 -t "$IMAGE" --push "$REPO/auth-proxy"

# --- deploy the Bicep template (creates the RG + everything in it) ---
note "Deploying Bicep to subscription (region $AZURE_REGION, group $AZURE_RESOURCE_GROUP)"
az deployment sub create \
  --name claude-mcp-deploy \
  --location "$AZURE_REGION" \
  --template-file "$REPO/infra/main.bicep" \
  --parameters "$REPO/infra/main.bicepparam" \
  --output none

FQDN="$(az deployment sub show --name claude-mcp-deploy --query properties.outputs.fqdn.value -o tsv)"
CALLBACK="$(az deployment sub show --name claude-mcp-deploy --query properties.outputs.callbackUrl.value -o tsv)"
MCP_URL="$(az deployment sub show --name claude-mcp-deploy --query properties.outputs.mcpUrl.value -o tsv)"

echo
note "Deployed. Endpoint: $MCP_URL"
if [ "$FIRST_PASS" -eq 1 ]; then
  cat <<EOF

NEXT (enable GitHub OAuth):
  1. Create a GitHub OAuth app (Settings > Developer settings > OAuth Apps):
       Homepage URL:               https://$FQDN
       Authorization callback URL: $CALLBACK
  2. Make the ghcr package PUBLIC once (GitHub > your packages > $AUTH_PROXY_IMAGE >
     Package settings > Change visibility > Public) so Container Apps can pull it.
  3. Put GITHUB_OAUTH_CLIENT_ID / GITHUB_OAUTH_CLIENT_SECRET (and real PATs) in .env.
  4. Re-run: bash scripts/deploy-azure.sh   (this enables GitHub OAuth.)
EOF
else
  cat <<EOF

Connect a client (see docs/atlassian-remote.md):
  Claude Code:    claude mcp add --transport http vnpay-atlassian $MCP_URL
  Claude Desktop: add a custom connector pointing at $MCP_URL
Confirm the GitHub OAuth app's callback URL is exactly: $CALLBACK
EOF
fi
