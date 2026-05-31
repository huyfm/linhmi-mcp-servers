"""Shared pytest fixtures for the read-only MCP integration tests.

These tests drive the REAL Atlassian MCP server over stdio (the same
`docker compose run --rm -T atlassian-mcp` Claude Code uses), so they require:
  * Docker daemon running
  * a real `.env` with valid URLs + Personal Access Tokens

If those prerequisites are missing, the whole suite is skipped (not failed) so
it stays portable. Every fixture is read-only.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from mcp_client import MCPClient, MCPError

ENV_FILE = Path(__file__).parent.parent / ".env"


def pytest_addoption(parser):
    parser.addoption("--project", default=None,
                     help="Jira project key to test (default: auto-discover)")
    parser.addoption("--page", default=None,
                     help="Confluence page id to test (default: auto-discover)")


def _docker_ready() -> bool:
    if shutil.which("docker") is None:
        return False
    try:
        return subprocess.run(["docker", "info"], capture_output=True,
                              timeout=15).returncode == 0
    except Exception:
        return False


@pytest.fixture(scope="session")
def mcp():
    """A connected, initialized read-only MCP client (one container per session)."""
    if not _docker_ready():
        pytest.skip("Docker daemon not available")
    if not ENV_FILE.exists():
        pytest.skip(".env not found — copy .env.example and fill in real values")
    if "replace-with-your" in ENV_FILE.read_text():
        pytest.skip(".env still contains placeholder token(s)")

    client = MCPClient()
    try:
        client.initialize()
    except MCPError as exc:
        client.close()
        pytest.skip(f"MCP server did not start: {exc}")
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
