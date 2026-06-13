# CLAUDE.md

Guidance for Claude Code / Claude when working in this repository.

## What this is

This repo deploys a **read-only** MCP (Model Context Protocol) server that lets Claude connect to VNPay's **self-hosted JIRA and Confluence (Atlassian Data Center)**. Its purpose is analysis and planning support: pull project timelines, issue assignments, sprints, estimates, and versioned Confluence wiki pages so Claude can reason about team effort and schedules.

It is a planning/analysis lens over JIRA and Confluence — **not** an automation tool. We do not build a custom MCP server; we deploy the community [`sooperset/mcp-atlassian`](https://github.com/sooperset/mcp-atlassian) image (MIT) **unchanged**, locked into read-only operation. It is hosted on **Azure Container Apps (Consumption)** as a remote **streamable-http over HTTPS** endpoint, fronted by a thin GitHub-OAuth gateway (`auth-proxy/`) so Claude Desktop (primary) and Claude Code (secondary) connect to one shared URL. (It previously ran over stdio for local use only; see git history.)

## NON-NEGOTIABLE: READ-ONLY

**This deployment must never create, update, or delete anything on JIRA or Confluence — even if the user explicitly asks for it.** If a user requests a write/mutation, refuse and explain that this deployment is read-only by design.

The image itself ships ~72 tools including writes; we neutralize them with **two independent layers**, both set in `.env`:

1. **`READ_ONLY_MODE=true`** — globally disables every write operation (create/update/delete/transition/comment) in `mcp-atlassian`.
2. **`ENABLED_TOOLS=<read-only allowlist>`** — only the read tools are even loaded. The `.env.example` ships the complete list of read-only Jira + Confluence tools and **zero** write tools.

**When editing this repo**: never set `READ_ONLY_MODE=false`, never add a write tool name to `ENABLED_TOOLS`, and never introduce a second MCP server or a direct API client that could mutate. Keep both layers intact. The `auth-proxy/` gateway is **auth-only** — it terminates GitHub OAuth and forwards the session to `mcp-atlassian`; it never talks to Jira/Confluence itself and must never gain a write path.

> Caveat that is NOT enforced here: a Data Center Personal Access Token has **no granular scopes** — it inherits the full permissions of the user who created it. So read-only is enforced by the *server software*, not the token. Use a dedicated **read-only service account** for the PAT so the credential itself cannot write even if the software guard were bypassed.

## Files

```
auth-proxy/          # Thin GitHub-OAuth gateway (our only custom code)
  app.py             #   FastMCP GitHubProvider + FastMCP.as_proxy -> localhost mcp-atlassian
  Dockerfile         #   built locally, pushed to PUBLIC ghcr.io; runs as the public-facing container
  requirements.txt   #   fastmcp, pinned
infra/               # Bicep IaC (deploys everything into the claude-mcp-rg resource group)
  main.bicep         #   subscription scope: creates claude-mcp-rg + invokes resources module
  resources.bicep    #   Log Analytics + Consumption env + 2-container Container App (native secrets)
  main.bicepparam    #   maps params to .env via readEnvironmentVariable (secrets read at deploy time)
docker-compose.yml   # LOCAL dev stack: mcp-atlassian (streamable-http) + auth-proxy (HTTP 8000)
.env.example         # Template: Azure deploy knobs + transport, URLs, PATs, READ_ONLY_MODE, ENABLED_TOOLS, GitHub OAuth
.env                 # Real secrets (gitignored — never commit); also drives the Bicep deploy
.gitignore           # Ignores .env and Python/build cruft

pyproject.toml       # uv project: pytest dev-dependency + pytest config (pythonpath/testpaths -> tests)
wiki/
  azure-deployment.md      # Bicep deploy guide (scripts/deploy-azure.sh) into claude-mcp-rg
  atlassian-remote.md      # Connect Claude Desktop (custom connector) + Claude Code to the remote endpoint
scripts/
  deploy-azure.sh                 # Build/push the proxy image + run the Bicep deployment
  destroy-azure.sh                # Delete claude-mcp-rg (one-command teardown)
  setup-jira-mcp.sh               # Register the remote HTTP endpoint with Claude Code
  smoke_test.py                   # Post-deploy health check: fails loudly if the live server isn't up + read-only + authenticated
tests/
  mcp_client.py      # Reusable read-only MCP streamable-http client used by the tests (on pytest pythonpath)
  conftest.py        # pytest fixtures: connected `mcp` client, project_key, page_id (+ skips)
  test_connectivity.py            # handshake, read-only tool posture, Jira+Confluence reachable
  test_timeline_and_versions.py   # Jira project timeline + 2 latest Confluence page versions
```

## Architecture

```
Claude Desktop / Claude Code
   │  remote MCP over HTTPS + GitHub OAuth bearer
   ▼
Azure Container Apps (Consumption) — one app, two containers in one pod
   ├─ auth-proxy      external HTTPS ingress :443 -> :8000   (GitHub OAuth gateway, our code)
   └─ mcp-atlassian   localhost :9000, streamable-http       (community image, UNCHANGED, read-only)
   │
   ▼ HTTPS REST + read-only service-account PAT
VNPay JIRA / Confluence (Data Center)
```

- **Transport:** `mcp-atlassian` runs `--transport streamable-http` on an internal port; only the `auth-proxy` reaches it. The proxy is the sole public surface (HTTPS, min TLS 1.2).
- **Endpoint auth:** GitHub OAuth, terminated by the `auth-proxy` (FastMCP `GitHubProvider`), which presents a DCR/PKCE-compliant OAuth surface so Claude Desktop's native custom connector and `mcp-remote` both work. `mcp-atlassian`'s own `Authorization: Bearer` handling is for Atlassian tokens, so the gateway must NOT reuse that header — the proxy forwards without it and `mcp-atlassian` falls back to its env service-account PAT.
- **Atlassian auth:** **Personal Access Token** (`JIRA_PERSONAL_TOKEN` / `CONFLUENCE_PERSONAL_TOKEN`), the standard for Jira/Confluence Data Center 8.14+. `JIRA_SSL_VERIFY` / `CONFLUENCE_SSL_VERIFY` handle internal CA certs.
- The `mcp-atlassian` image tag is pinned via `MCP_ATLASSIAN_TAG` (and `fastmcp` is pinned in `auth-proxy/requirements.txt`) for supply-chain safety — prefer specific releases over `latest`.
- **Cost/secrets posture (lowest cost):** the `auth-proxy` image lives on **public ghcr.io** (pulled anonymously — no ACR), and the three secrets (both PATs + GitHub client secret) are **native Container Apps secrets** (no Key Vault, no managed identity). Container App is two 0.25-vCPU/0.5-GiB containers, `minReplicas=0` (scale-to-zero, no idle cost — stays within the Consumption free grant; trade-off is an HTTP cold start after idle) and `maxReplicas=1` (preserves the single-pod shared-localhost topology).
- **Provisioning:** Bicep in `infra/`, deployed by `scripts/deploy-azure.sh` into `claude-mcp-rg` — see `wiki/azure-deployment.md`. (No azd/Terraform.)

## Commands

```bash
cp .env.example .env        # then edit: real URLs, PATs (read-only service account)

# Local dev: run the proxy + mcp-atlassian together (set AUTH_DISABLED=true in .env to skip OAuth locally):
docker compose up --build
curl -s localhost:8000/mcp  # the streamable-http endpoint via the proxy

# Deploy to Azure (Bicep -> claude-mcp-rg). Builds/pushes the proxy image, then deploys.
# First run (GitHub creds still placeholders) comes up auth-disabled and prints the FQDN + callback.
bash scripts/deploy-azure.sh
bash scripts/destroy-azure.sh   # tear it all down (deletes claude-mcp-rg)

# Register the remote endpoint with Claude Code:
claude mcp add --transport http vnpay-atlassian https://<your-container-app-fqdn>/mcp
#   (Claude Desktop connects via a native custom connector — see wiki/atlassian-remote.md)
```

## Read-only tools available (for analysis)

Timeline / effort / assignment (Jira): `jira_search`, `jira_get_issue`, `jira_get_project_issues`, `jira_get_sprints_from_board`, `jira_get_sprint_issues`, `jira_get_board_issues`, `jira_get_worklog`, `jira_get_issue_dates`, `jira_get_project_versions`, `jira_batch_get_changelogs`, plus project/board/field lookups.

Wiki + versioning (Confluence): `confluence_search`, `confluence_get_page`, `confluence_get_page_children`, `confluence_get_page_history`, `confluence_get_page_diff`, `confluence_get_comments`, `confluence_get_labels`.

(Full allowlist is in `.env.example` under `ENABLED_TOOLS`.)

## Testing

Tests use **pytest**, managed by **uv** (pytest is the only dependency, declared in `pyproject.toml` under `[dependency-groups] dev`). They are **integration** tests: each marked `@pytest.mark.integration`, they drive the **real** MCP server over **streamable-http** the same way Claude Code does. They read `MCP_BASE_URL` (the `/mcp` endpoint) and optional `MCP_BEARER_TOKEN`. If `MCP_BASE_URL` is unset or unreachable the suite **skips** (not fails), via fixtures in `conftest.py`. All tests are read-only.

```bash
# Point at a running endpoint first (local compose with AUTH_DISABLED=true, or Azure with a token):
export MCP_BASE_URL=http://localhost:8000/mcp
uv run pytest                                   # run everything (auto-discovers a project + page)
uv run pytest --project ACV2 --page 972883831   # target a specific project / page
uv run pytest tests/test_connectivity.py -v     # just connectivity
```

- `tests/mcp_client.py` — minimal streamable-http JSON-RPC client (`MCPClient.initialize()` / `.list_tools()` / `.call()` / `.call_json()`), stdlib-only, handling JSON and SSE responses plus the `Mcp-Session-Id`. It exposes **no write helper**; tests can only read. Reuse it for any new read-only checks.
- `tests/conftest.py` — session-scoped `mcp` fixture (skips unless `MCP_BASE_URL` is set and the endpoint initializes) plus `project_key` and `page_id` fixtures (honor `--project` / `--page`, else auto-discover).
- `tests/test_connectivity.py` — server initializes, the read-only allowlist is loaded (no real write tools), Jira + Confluence reachable/authenticated.
- `tests/test_timeline_and_versions.py` — reads a project's release versions and issue timeline (created/due/resolution dates + assignees), and reads a Confluence page at its **two latest versions** (asserting they differ) plus the diff between them.
  - Versioning mechanism: `confluence_get_page` (with `include_metadata`) yields the current version number `N`; `confluence_get_page_history(page_id, version=N-1)` returns the full content **at that version**. So "two latest versions" = read `N` (current) + `N-1` (history), with `confluence_get_page_diff` for what changed.

When adding tests, keep them read-only, mark them `integration`, and route all calls through `MCPClient`.

## Conventions

- Secrets live only in `.env` (gitignored) locally and in **Key Vault** in Azure. Never log, echo, or commit a PAT or the GitHub client secret.
- Jira issue queries use **JQL**; Confluence search uses **CQL**.
- Keep both read-only layers, keep `mcp-atlassian` internal (never give it external ingress directly), and keep the `auth-proxy` as the only public surface when changing compose/env/infra.
- Markdown: do not hard-wrap. Write each paragraph (and list item) as one continuous line with no manual line breaks; let it soft-wrap in the editor.
