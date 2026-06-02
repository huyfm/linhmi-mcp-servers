"""Shared pytest fixtures for the read-only MCP integration tests.

These tests drive the REAL Atlassian MCP server over **streamable-http** (the
same remote endpoint Claude Code / Claude Desktop use, i.e. the auth-proxy in
front of mcp-atlassian), so they require:
  * MCP_BASE_URL pointing at the running endpoint, e.g.
      http://localhost:8000/mcp   (local `docker compose up`, AUTH_DISABLED=true)
      https://<fqdn>/mcp          (Azure; also set MCP_BEARER_TOKEN)
  * MCP_BEARER_TOKEN when the endpoint enforces GitHub OAuth

If MCP_BASE_URL is unset or the endpoint is unreachable, the whole suite is
skipped (not failed) so it stays portable. Every fixture is read-only.
"""

from __future__ import annotations

import os

import pytest

from mcp_client import MCPClient, MCPError


def pytest_addoption(parser):
    parser.addoption("--project", default=None,
                     help="Jira project key to test (default: auto-discover)")
    parser.addoption("--page", default=None,
                     help="Confluence page id to test (default: auto-discover)")


@pytest.fixture(scope="session")
def mcp():
    """A connected, initialized read-only MCP client (streamable-http)."""
    if not os.environ.get("MCP_BASE_URL"):
        pytest.skip("MCP_BASE_URL not set — point it at the running /mcp endpoint")

    try:
        client = MCPClient()
        client.initialize()
    except MCPError as exc:
        pytest.skip(f"MCP endpoint not reachable / did not initialize: {exc}")
    yield client
    client.close()


@pytest.fixture(scope="session")
def project_key(mcp, request) -> str:
    """The Jira project under test: --project, else the first one returned."""
    opt = request.config.getoption("--project")
    if opt:
        return opt
    projects = mcp.call_json("jira_get_all_projects")
    if not isinstance(projects, list) or not projects:
        pytest.skip("no Jira projects visible to this account")
    return projects[0]["key"]


@pytest.fixture(scope="session")
def page_id(mcp, request) -> str:
    """The Confluence page under test: --page, else one found via search."""
    opt = request.config.getoption("--page")
    if opt:
        return opt
    found = mcp.call_json("confluence_search",
                          {"query": "type = page", "limit": 5})
    results = found if isinstance(found, list) else found.get("results", [])
    if not results:
        pytest.skip("no Confluence pages visible to this account")
    return str(results[0]["id"])
