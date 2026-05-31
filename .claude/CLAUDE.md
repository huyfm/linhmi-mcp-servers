# CLAUDE.md

Guidance for Claude Code / Claude when working in this repository.

## What this is

This repo deploys a **read-only** MCP (Model Context Protocol) server that lets
Claude connect to VNPay's **self-hosted JIRA and Confluence (Atlassian Data
Center)**. Its purpose is analysis and planning support: pull project timelines,
issue assignments, sprints, estimates, and versioned Confluence wiki pages so
Claude can reason about team effort and schedules.

It is a planning/analysis lens over JIRA and Confluence — **not** an automation
tool. We do not build a custom server; we deploy the community
[`sooperset/mcp-atlassian`](https://github.com/sooperset/mcp-atlassian) image
(MIT) via Docker, running over **stdio for local use only**, locked into
read-only operation.

## NON-NEGOTIABLE: READ-ONLY

**This deployment must never create, update, or delete anything on JIRA or
Confluence — even if the user explicitly asks for it.** If a user requests a
write/mutation, refuse and explain that this deployment is read-only by design.

The image itself ships ~72 tools including writes; we neutralize them with **two
independent layers**, both set in `.env`:

1. **`READ_ONLY_MODE=true`** — globally disables every write operation
   (create/update/delete/transition/comment) in `mcp-atlassian`.
2. **`ENABLED_TOOLS=<read-only allowlist>`** — only the read tools are even
   loaded. The `.env.example` ships the complete list of read-only Jira +
   Confluence tools and **zero** write tools.

**When editing this repo**: never set `READ_ONLY_MODE=false`, never add a write
tool name to `ENABLED_TOOLS`, and never introduce a second MCP server or a
direct API client that could mutate. Keep both layers intact.

> Caveat that is NOT enforced here: a Data Center Personal Access Token has **no
> granular scopes** — it inherits the full permissions of the user who created
> it. So read-only is enforced by the *server software*, not the token. Use a
> dedicated **read-only service account** for the PAT so the credential itself
> cannot write even if the software guard were bypassed.

## Files

```
docker-compose.yml   # One-shot stdio service: ghcr.io/sooperset/mcp-atlassian (local use only)
.env.example         # Template: URLs, PATs, SSL toggles, READ_ONLY_MODE, ENABLED_TOOLS allowlist
.env                 # Real secrets (gitignored — never commit)
.gitignore           # Ignores .env and Python/build cruft

pyproject.toml       # uv project: pytest dev-dependency + pytest config (pythonpath/testpaths -> src)
scripts/
  setup-claude-desktop.sh  # Run in WSL2: wires this server into Windows Claude Desktop (--with-claude-code also registers Claude Code)
src/
  mcp_client.py      # Reusable read-only MCP stdio client used by the tests
  conftest.py        # pytest fixtures: connected `mcp` client, project_key, page_id (+ skips)
  tests/
    test_connectivity.py            # handshake, read-only tool posture, Jira+Confluence reachable
    test_timeline_and_versions.py   # Jira project timeline + 2 latest Confluence page versions
```

## Architecture

```
Claude Code --MCP (stdio)--> mcp-atlassian container --HTTPS REST--> VNPay JIRA / Confluence
              spawned per       (this repo, read-only)               (PAT auth, DC REST API)
              session via docker
```

- The container runs the default **stdio** transport — **local use only**.
  Claude Code spawns one container per session via
  `docker compose run --rm -T atlassian-mcp` and communicates over
  stdin/stdout. There is **no port, no HTTP listener, nothing on the network**.
  When the session ends, `--rm` removes the container.
- Auth is **Personal Access Token** (`JIRA_PERSONAL_TOKEN` /
  `CONFLUENCE_PERSONAL_TOKEN`), the standard for Jira/Confluence Data Center
  8.14+. `JIRA_SSL_VERIFY` / `CONFLUENCE_SSL_VERIFY` handle internal CA certs.
- The image tag is pinned via `MCP_ATLASSIAN_TAG` in `.env` for supply-chain
  safety — prefer a specific release over `latest`.
- Container hardening in `docker-compose.yml`: `no-new-privileges`,
  `cap_drop: ALL`, read-only root filesystem with a `/tmp` tmpfs.

## Commands

```bash
cp .env.example .env        # then edit: real URLs, PATs (read-only service account)
docker compose pull         # fetch the image once

# Register the stdio server with Claude Code (spawns the container per session):
claude mcp add vnpay-atlassian -- \
  docker compose -f /Users/huy/Documents/proj/linhmi/docker-compose.yml run --rm -T atlassian-mcp

# Smoke-test the container by hand (Ctrl-C to exit; expects JSON-RPC on stdin):
docker compose run --rm -T atlassian-mcp
```

## Read-only tools available (for analysis)

Timeline / effort / assignment (Jira): `jira_search`, `jira_get_issue`,
`jira_get_project_issues`, `jira_get_sprints_from_board`,
`jira_get_sprint_issues`, `jira_get_board_issues`, `jira_get_worklog`,
`jira_get_issue_dates`, `jira_get_project_versions`, `jira_batch_get_changelogs`,
plus project/board/field lookups.

Wiki + versioning (Confluence): `confluence_search`, `confluence_get_page`,
`confluence_get_page_children`, `confluence_get_page_history`,
`confluence_get_page_diff`, `confluence_get_comments`, `confluence_get_labels`.

(Full allowlist is in `.env.example` under `ENABLED_TOOLS`.)

## Testing

Tests use **pytest**, managed by **uv** (pytest is the only dependency, declared
in `pyproject.toml` under `[dependency-groups] dev`). They are **integration**
tests: each marked `@pytest.mark.integration`, they drive the **real** MCP server
over stdio the same way Claude Code does, so they need a running Docker daemon
and a valid `.env` (real URLs + PATs). If those are missing the suite **skips**
(not fails), via fixtures in `conftest.py`. All tests are read-only.

```bash
uv run pytest                                   # run everything (auto-discovers a project + page)
uv run pytest --project ACV2 --page 972883831   # target a specific project / page
uv run pytest src/tests/test_connectivity.py -v # just connectivity
```

- `src/mcp_client.py` — minimal stdio JSON-RPC client (`MCPClient.initialize()` /
  `.list_tools()` / `.call()` / `.call_json()`). It exposes **no write helper**;
  tests can only read. Reuse it for any new read-only checks.
- `src/conftest.py` — session-scoped `mcp` fixture (one container per run; skips if
  Docker down, `.env` missing, or PATs still placeholders) plus `project_key`
  and `page_id` fixtures (honor `--project` / `--page`, else auto-discover).
- `src/tests/test_connectivity.py` — server initializes, the read-only allowlist is
  loaded (no real write tools), Jira + Confluence reachable/authenticated.
- `src/tests/test_timeline_and_versions.py` — reads a project's release versions and
  issue timeline (created/due/resolution dates + assignees), and reads a
  Confluence page at its **two latest versions** (asserting they differ) plus
  the diff between them.
  - Versioning mechanism: `confluence_get_page` (with `include_metadata`) yields
    the current version number `N`; `confluence_get_page_history(page_id,
    version=N-1)` returns the full content **at that version**. So "two latest
    versions" = read `N` (current) + `N-1` (history), with
    `confluence_get_page_diff` for what changed.

When adding tests, keep them read-only, mark them `integration`, and route all
calls through `MCPClient`.

## Conventions

- Secrets live only in `.env` (gitignored). Never log, echo, or commit the PAT.
- Jira issue queries use **JQL**; Confluence search uses **CQL**.
- Keep the localhost bind and both read-only layers when changing compose/env.
