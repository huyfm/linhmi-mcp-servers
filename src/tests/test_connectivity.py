"""Connectivity / read-only-posture checks against the live MCP server."""

import pytest

pytestmark = pytest.mark.integration

# Substrings that indicate a genuine mutating tool. `get_transitions` is a READ
# tool (it only lists available transitions) so we exclude that false positive.
_WRITE_HINTS = ("create", "update", "delete", "add_", "edit_",
                "transition_", "remove", "move_", "upload", "reply_")


def test_server_initializes(mcp):
    # The `mcp` fixture already performed initialize(); a tools/list round-trip
    # confirms the session is live and responsive.
    tools = mcp.list_tools()
    assert len(tools) > 0


def test_only_read_tools_loaded(mcp):
    names = [t["name"] for t in mcp.list_tools()]
    writes = [n for n in names if any(h in n for h in _WRITE_HINTS)]
    assert writes == [], f"write tools unexpectedly exposed: {writes}"
    # the read tools our use case depends on must be present
    for required in ("jira_search", "jira_get_issue", "confluence_search",
                     "confluence_get_page", "confluence_get_page_history"):
        assert required in names, f"{required} not loaded"


def test_jira_reachable(mcp):
    projects = mcp.call_json("jira_get_all_projects")
    assert isinstance(projects, list), f"unexpected payload: {projects!r:.120}"
    # an authenticated account should see at least one project
    assert len(projects) >= 1


def test_confluence_reachable(mcp):
    found = mcp.call_json("confluence_search",
                          {"query": "type = page", "limit": 1})
    results = found if isinstance(found, list) else found.get("results", [])
    assert isinstance(results, list)
