# Azure deployment — read-only Atlassian MCP over HTTPS (Bicep)

This deploys the read-only Atlassian MCP server to Azure Container Apps using Bicep for the infrastructure and a thin wrapper script for the steps Bicep can't do (build/push the gateway image, pass secrets). Everything lands in one resource group, `claude-mcp-rg`, so teardown is a single command. Choices are biased toward lowest cost throughout.

## What you are building

One Azure Container App running two containers in a single pod:

- `auth-proxy` — our GitHub-OAuth gateway (`auth-proxy/`), the only thing exposed to the internet (external HTTPS ingress on port 8000). It terminates GitHub OAuth and proxies the authenticated MCP session to the second container over `localhost`.
- `mcp-atlassian` — the unchanged community image, listening only on `localhost:9000`, locked read-only by `READ_ONLY_MODE=true` and the `ENABLED_TOOLS` allowlist, authenticating to VNPay Jira/Confluence with one read-only service-account PAT.

```
Internet ──HTTPS──> Container App ingress :443
                       └─ auth-proxy        (targetPort 8000, external)
                            └─ localhost ──> mcp-atlassian (:9000, internal)
                                                  └─ HTTPS + read-only PAT ──> Jira / Confluence
```

## Lowest-cost design

- No Azure Container Registry: the `auth-proxy` image is built locally and pushed to a public ghcr.io repo, pulled anonymously. Saves the ~$5/mo ACR Basic and the need for a pull identity.
- No Key Vault and no managed identity: the three secrets (Jira PAT, Confluence PAT, GitHub client secret) are stored as native Container Apps secrets (encrypted at rest, $0, fewest moving parts). Key Vault is a reasonable hardening upgrade later, but it is not the lowest-cost or simplest option, so it is intentionally not used here.
- Container Apps Consumption environment (no standing charge) with both containers at the smallest valid size, 0.25 vCPU / 0.5 GiB each (0.5 / 1.0 total). `minReplicas=0` (scale-to-zero) means there is no standing compute cost: when idle the app drops to zero replicas and usage stays within the Consumption monthly free grant. The first request after an idle period pays an HTTP cold start (the pod and both containers spin up), which adds a few seconds of latency that MCP clients retry through. `maxReplicas=1` keeps the single-pod shared-localhost topology so the proxy always reaches `mcp-atlassian` on `localhost`.
- A Log Analytics workspace is created for logs; ingestion at this volume stays within the monthly free allowance.

### Cold start does not force a re-login

A scale-to-zero cold start does **not** make users re-authenticate with GitHub. The `auth-proxy` validates each incoming bearer statelessly: `OAuthProxy.load_access_token` delegates to `GitHubTokenVerifier.verify_token`, which calls `https://api.github.com/user` live on every request — it does not depend on the proxy's in-memory token/client maps. Because the deployment uses a GitHub **OAuth App** (whose user access tokens don't expire by default), the client's cached token keeps validating across cold starts, so a recycled replica just means boot latency on the first request, not a fresh SSO. The only narrow case that re-prompts is a replica recycling mid-login (in the brief window between `/authorize` and the `/token` callback), since that in-flight transaction state is in memory; established sessions are unaffected.

## Files

- `infra/main.bicep` — subscription-scoped entry point. Creates `claude-mcp-rg` and deploys everything into it. Composes the ghcr image reference and takes the three secrets as `@secure()` params.
- `infra/resources.bicep` — the resources: Log Analytics (`claude-mcp-logs`), the Consumption environment, and the Container App (two containers, native secrets, scale 1/1). It computes `PUBLIC_BASE_URL` from the environment's default domain, so no second deploy is needed to learn the URL.
- `infra/main.bicepparam` — maps parameters to your `.env` via `readEnvironmentVariable(...)`. Secrets are read from the environment at deploy time, never stored in the file.
- `scripts/deploy-azure.sh` — builds/pushes the image, then runs the deployment with your `.env` exported.
- `scripts/destroy-azure.sh` — deletes `claude-mcp-rg`.

## Prerequisites

- Azure CLI logged in: `az login`, then `az account set --subscription "<your-subscription>"`. The script installs Bicep automatically if needed.
- Docker (to build the gateway image) and a way to push to ghcr: either `GHCR_TOKEN` (a GitHub PAT with `write:packages`) in your `.env`, or the `gh` CLI logged in.
- A read-only Jira/Confluence service-account PAT (Data Center). Use a dedicated read-only account — the server software enforces read-only, but the token itself inherits the account's permissions.

## Step 1 — configure .env

```bash
cp .env.example .env
```

Fill in: `JIRA_URL`, `CONFLUENCE_URL`, the two PATs, and `GHCR_USER` (your GitHub username/org). Leave the `GITHUB_OAUTH_*` values as placeholders for now — you cannot create the GitHub OAuth app until you know the app's URL, which you get from the first deploy.

## Step 2 — first deploy (discovers the FQDN, auth disabled)

```bash
bash scripts/deploy-azure.sh
```

Because the GitHub OAuth creds are still placeholders, the script deploys with authentication disabled so the app comes up, then prints the public FQDN and the exact OAuth callback URL. It creates the resource group, Log Analytics, the environment, builds and pushes the `auth-proxy` image, and deploys the Container App.

## Step 3 — create the GitHub OAuth app and make the image public

1. GitHub > Settings > Developer settings > OAuth Apps > New OAuth App.
   - Homepage URL: `https://<the FQDN printed in step 2>`
   - Authorization callback URL: the callback URL printed in step 2 (`https://<fqdn>/auth/callback`).
   Copy the Client ID and generate a Client Secret.
2. Make the ghcr package public once so Container Apps can pull it anonymously: GitHub > your profile > Packages > `vnpay-atlassian-auth-proxy` > Package settings > Change visibility > Public.
3. Put the real values in `.env`: `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, and (if not already) the real PATs. Optionally set `ALLOWED_GITHUB_USERS` to a comma-separated list of GitHub logins.

## Step 4 — re-deploy with GitHub OAuth enabled

```bash
bash scripts/deploy-azure.sh
```

With real creds present, the script deploys with auth enabled. Bicep is declarative, so this just converges the existing app.

## Verify

1. Revision is healthy: `az containerapp revision list -g claude-mcp-rg -n vnpay-atlassian-mcp -o table` shows the latest revision Running and Healthy.
2. OAuth metadata is served: `curl -s https://<fqdn>/.well-known/oauth-protected-resource` returns JSON, and `https://<fqdn>/.well-known/oauth-authorization-server` returns the GitHub-federated metadata.
3. Logs look right: `az containerapp logs show -g claude-mcp-rg -n vnpay-atlassian-mcp --container mcp-atlassian --tail 50` shows streamable-http serving with `READ_ONLY_MODE=true`; `--container auth-proxy` shows `auth=GitHub OAuth`.
4. Connect a client (see `wiki/atlassian-remote.md`): Claude Desktop via a native custom connector at `https://<fqdn>/mcp`, or Claude Code with `claude mcp add --transport http vnpay-atlassian https://<fqdn>/mcp`. Confirm `tools/list` shows only the read-only allowlist.

## Updating

- New `auth-proxy` code: bump `AUTH_PROXY_TAG` in `.env` and re-run `scripts/deploy-azure.sh` (it rebuilds, repushes, and re-deploys with the new tag).
- Rotate a PAT or the GitHub secret: update `.env` and re-run the script.
- If either container is starved under load, raise both to the next valid combo (0.5 vCPU / 1.0 GiB) by editing the `cpu`/`memory` vars in `infra/resources.bicep`.

## Teardown

```bash
bash scripts/destroy-azure.sh        # deletes claude-mcp-rg and everything in it
```

## Native secrets vs Key Vault

This deployment stores secrets as Container Apps secrets (encrypted at rest, no extra resource, no identity). If you later want centralized rotation, auditing, or to share secrets across apps, switch the `secrets` block in `infra/resources.bicep` to Key Vault references and add a user-assigned managed identity with the Key Vault Secrets User role. That is strictly more resources and a bit more cost, which is why it is not the default here.
