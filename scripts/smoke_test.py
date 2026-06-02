#!/usr/bin/env python3
"""Post-deploy smoke test for the read-only Atlassian MCP server.

Unlike the pytest suite (tests/), which SKIPS when the endpoint is unset or
unreachable so it stays portable, this is an operational check: it FAILS LOUDLY
(non-zero exit) the moment anything is wrong. Run it right after a deploy or a
revision restart to confirm the server is alive, locked to read-only, and that
the Jira + Confluence credentials actually authenticate.

It drives the real server over streamable-http exactly like Claude Code does,
reusing the same client as the tests (so it inherits the session-id handling).

Usage:
  # Local stack (docker compose up, AUTH_DISABLED=true):
  MCP_BASE_URL=http://localhost:8000/mcp uv run python scripts/smoke_test.py

  # Deployed Azure endpoint (GitHub OAuth -> pass a bearer token):
  MCP_BASE_URL=https://<fqdn>/mcp MCP_BEARER_TOKEN=<token> uv run python scripts/smoke_test.py

Environment:
  MCP_BASE_URL      full /mcp endpoint URL. Required.
  MCP_BEARER_TOKEN  GitHub-OAuth bearer for the auth-proxy. Required for Azure;
                    omit for a local AUTH_DISABLED=true stack.

Exit codes: 0 = all checks passed, 1 = a check failed, 2 = misconfiguration.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Reuse the test client (tests/ is on the pytest pythonpath, but a standalone
# script run needs it added explicitly).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tests"))

from mcp_client import MCPClient, MCPError  # noqa: E402

# Substrings that betray a genuine mutating tool. `get_transitions` only LISTS
# transitions, so it is a read tool and must not trip this (kept in sync with
# tests/test_connectivity.py).
WRITE_HINTS = ("create", "update", "delete", "add_", "edit_",
               "transition_", "remove", "move_", "upload", "reply_")

# Read tools our analysis use case depends on; their presence is part of "healthy".
REQUIRED_TOOLS = ("jira_search", "jira_get_issue", "confluence_search",
                  "confluence_get_page", "confluence_get_page_history")


class SmokeFailure(Exception):
    """A smoke check that did not pass."""


def _check(name: str, fn) -> bool:
    """Run one check, print a single PASS/FAIL line, never raise."""
    try:
        detail = fn()
        print(f"PASS  {name}" + (f" - {detail}" if detail else ""))
        return True
    except Exception as exc:  # noqa: BLE001 - a smoke test reports every failure
        print(f"FAIL  {name} - {exc}")
        return False


def main() -> int:
    base_url = os.environ.get("MCP_BASE_URL", "")
    if not base_url:
        print("FAIL  config - MCP_BASE_URL is not set; point it at the /mcp endpoint", file=sys.stderr)
        return 2

    token = os.environ.get("MCP_BEARER_TOKEN", "")
    auth = "with bearer token" if token else "no bearer token (expecting AUTH_DISABLED)"
    print(f"Smoke testing {base_url} ({auth})")

    client = MCPClient()

    # The handshake is a prerequisite for everything else: if it fails, stop here.
    try:
        info = client.initialize()
    except MCPError as exc:
        print(f"FAIL  initialize - {exc}")
        return 1
    server = info.get("serverInfo", {})
    print(f"PASS  initialize - {server.get('name', '?')} {server.get('version', '')}".rstrip())

    # Gather the tool list once and reuse it across posture checks.
    tools = client.list_tools()
    names = [t["name"] for t in tools]

    def check_tools_present():
        if not names:
            raise SmokeFailure("server exposed zero tools")
        return f"{len(names)} tools exposed"

    def check_no_write_tools():
        writes = [n for n in names if any(h in n for h in WRITE_HINTS)]
        if writes:
            raise SmokeFailure(f"write tools unexpectedly exposed: {writes}")
        return "no write tools exposed"

    def check_required_tools():
        missing = [t for t in REQUIRED_TOOLS if t not in names]
        if missing:
            raise SmokeFailure(f"required read tools missing: {missing}")
        return "all required read tools present"

    def check_jira_credentials():
        projects = client.call_json("jira_get_all_projects")
        if not isinstance(projects, list) or not projects:
            raise SmokeFailure(f"jira_get_all_projects returned no projects: {projects!r:.120}")
        return f"Jira authenticated, {len(projects)} project(s) visible"

    def check_confluence_credentials():
        found = client.call_json("confluence_search", {"query": "type = page", "limit": 1})
        results = found if isinstance(found, list) else found.get("results", [])
        if not isinstance(results, list):
            raise SmokeFailure(f"confluence_search returned unexpected payload: {found!r:.120}")
        return f"Confluence authenticated, {len(results)} page(s) in sample"

    checks = [
        ("tools listed", check_tools_present),
        ("read-only posture: no write tools", check_no_write_tools),
        ("read-only posture: required read tools", check_required_tools),
        ("jira credentials", check_jira_credentials),
        ("confluence credentials", check_confluence_credentials),
    ]

    ok = all(_check(name, fn) for name, fn in checks)
    client.close()

    print()
    if ok:
        print("SMOKE TEST PASSED")
        return 0
    print("SMOKE TEST FAILED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
