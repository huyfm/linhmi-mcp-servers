# VNPay Atlassian MCP — read-only JIRA and Confluence for Claude

This connects Claude to VNPay's self-hosted JIRA and Confluence so you can ask about project timelines, task assignments, sprints, estimates, and wiki pages in plain language. Claude only reads — it can never create, edit, or delete anything on JIRA or Confluence.

There are two guides below. Most people only need the first one.

- [For everyone: connect Claude Desktop](#for-everyone-connect-claude-desktop) — use the shared server an admin already deployed. No setup, no command line.
- [For engineers: deploy your own server](#for-engineers-deploy-your-own-server) — stand up the whole thing on your own Azure account.

---

## For everyone: connect Claude Desktop

### What you need

- Claude Desktop installed on your computer.
- A GitHub account that has been granted access. If you are not sure you have access, message the admin with your GitHub username.

### Connect it (one time)

1. Open Claude Desktop, go to Customize (or Settings) > Connectors.
2. Click the **+** and choose **Add custom connector**.
3. Set the Name to `VNPay Atlassian`, and paste this into the URL field (leave Advanced settings empty):

   ```
   https://vnpay-atlassian-mcp.politeisland-ad6a6562.southeastasia.azurecontainerapps.io/mcp
   ```

4. Under **Need approvals**, switch to **Always allow** so Claude does not ask for confirmation on every lookup.
5. Click **Add**. A browser window opens for you to sign in to GitHub — approve the access request.
6. Done. The connector stays added and you will not have to sign in again next time.

### Turn it on in a chat

In each conversation, click the **+** at the bottom-left of the chat box, choose **Connectors**, and switch on `VNPay Atlassian`. Now you can ask Claude about JIRA and Confluence.

### What you can ask

- "List the tasks that are currently In Progress."
- "Summarize the progress and owners for the VNPSHOPNEW project."
- "What are the high-priority tasks in progress in the VNPVNCALL project?"
- "What changed on this Confluence page compared to the previous version?"

### If something goes wrong

- Signed in but cannot look anything up: your GitHub account has not been granted access yet. Message the admin with your GitHub username.
- Cannot connect at all: the server may be waking from idle (see the note below) — try again in a few seconds. If it still fails, tell the admin.
- Want to switch to a different GitHub account: go to Customize > Connectors, remove the connector, and add it again with the steps above.
- The connector is not available to turn on in a chat: re-check that you added it under Customize > Connectors. On a Team/Enterprise plan, an Owner may first need to add the connector under Organization settings > Connectors, after which you go to Customize > Connectors and click Connect to sign in.

### Note on the first request being slow

To keep cost at zero, the server sleeps when nobody is using it and wakes on the next request. The first lookup after a quiet period can take a few extra seconds while it wakes up; after that it is fast. This is expected and not a fault.

---

## For engineers: deploy your own server

This repo deploys the community [`sooperset/mcp-atlassian`](https://github.com/sooperset/mcp-atlassian) image unchanged, locked into read-only mode, onto Azure Container Apps. A thin GitHub-OAuth gateway (`auth-proxy/`) is the only public surface; it terminates GitHub OAuth and forwards the session to `mcp-atlassian` over localhost. Read-only is enforced by two independent layers — `READ_ONLY_MODE=true` and an `ENABLED_TOOLS` allowlist that loads only read tools.

```
Claude Desktop / Claude Code
   │  HTTPS + GitHub OAuth
   ▼
Azure Container App (one pod, two containers)
   ├─ auth-proxy      external HTTPS :443 -> :8000   (GitHub OAuth gateway, our code)
   └─ mcp-atlassian   localhost :9000                (community image, unchanged, read-only)
   │  HTTPS + read-only service-account PAT
   ▼
VNPay JIRA / Confluence (Data Center)
```

### Prerequisites

- Azure CLI logged in (`az login`, then `az account set --subscription "<sub>"`).
- Docker, plus a way to push to ghcr.io: a `GHCR_TOKEN` (GitHub PAT with `write:packages`) in `.env`, or the `gh` CLI logged in.
- A dedicated read-only JIRA/Confluence service-account Personal Access Token (Data Center 8.14+). Read-only is enforced by the server, not the token, so use a least-privilege account.

### Deploy

```bash
cp .env.example .env        # fill in JIRA_URL, CONFLUENCE_URL, the two PATs, GHCR_USER

# First deploy: GitHub OAuth creds are still placeholders, so it comes up with auth
# disabled and prints the public FQDN + the exact OAuth callback URL.
bash scripts/deploy-azure.sh

# Then create a GitHub OAuth App (callback = https://<fqdn>/auth/callback), make the
# pushed ghcr.io package Public so Azure can pull it anonymously, and put the real
# GITHUB_OAUTH_CLIENT_ID / GITHUB_OAUTH_CLIENT_SECRET in .env.
bash scripts/deploy-azure.sh   # re-deploy, now with GitHub OAuth enabled

bash scripts/destroy-azure.sh  # tear everything down (deletes claude-mcp-rg)
```

Full step-by-step, including the OAuth app setup and verification commands, is in [wiki/azure-deployment.md](wiki/azure-deployment.md). Client setup for Claude Desktop and Claude Code is in [wiki/atlassian-remote.md](wiki/atlassian-remote.md):

```bash
claude mcp add --transport http vnpay-atlassian https://<your-fqdn>/mcp
```

### Note on free-tier cost and cold starts

The deployment is tuned to stay within Azure's free grant: no Container Registry (the proxy image is pulled anonymously from public ghcr.io), no Key Vault (secrets are native Container Apps secrets), and `minReplicas=0` so there is no idle compute cost. The trade-off is an HTTP cold start of a few seconds on the first request after the app scales to zero — MCP clients retry through it. This does not force users to re-authenticate. The cost reasoning and the exact knobs are documented in [wiki/azure-deployment.md](wiki/azure-deployment.md).

### Read-only by design

This deployment must never create, update, or delete anything on JIRA or Confluence, even on request. The image ships write tools; both `READ_ONLY_MODE=true` and the `ENABLED_TOOLS` read allowlist neutralize them, and the auth-proxy is auth-only with no path to Atlassian. See [.claude/CLAUDE.md](.claude/CLAUDE.md) for the full contract before changing anything.
