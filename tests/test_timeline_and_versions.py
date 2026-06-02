"""Functional read-only tests:

  1. read the TIMELINE of a particular Jira project
     (release versions + issues with created/due/resolution dates + assignees);
  2. read a particular Confluence wiki page at its TWO LATEST VERSIONS
     (and confirm they differ + a diff is available).

Target is auto-discovered by default; pass --project KEY / --page ID to pin one.
All calls are pure reads.
"""

import pytest

pytestmark = pytest.mark.integration


# --- helpers --------------------------------------------------------------
def _unwrap(value, default=""):
    """Unwrap {'displayName'|'name'|'value': ...} dicts to a scalar."""
    if isinstance(value, dict):
        for label in ("displayName", "name", "value"):
            if label in value:
                return value[label]
    return value if value not in (None, "") else default


def _field(issue, name, default=""):
    fields = issue.get("fields", issue)
    return _unwrap(fields.get(name), default)


def _issues_of(payload):
    if isinstance(payload, dict):
        return payload.get("issues", [])
    return payload if isinstance(payload, list) else []


def _find_version_number(obj):
    """Recursively locate the current version number in a get_page payload."""
    if isinstance(obj, dict):
        v = obj.get("version")
        if isinstance(v, int):
            return v
        if isinstance(v, dict) and isinstance(v.get("number"), int):
            return v["number"]
        for val in obj.values():
            n = _find_version_number(val)
            if n is not None:
                return n
    elif isinstance(obj, list):
        for val in obj:
            n = _find_version_number(val)
            if n is not None:
                return n
    return None


# --- TEST 1: Jira project timeline ---------------------------------------
def test_project_release_versions(mcp, project_key):
    versions = mcp.call_json("jira_get_project_versions",
                             {"project_key": project_key})
    vlist = versions if isinstance(versions, list) else versions.get("values", [])
    assert isinstance(vlist, list)  # may legitimately be empty
    for v in vlist:
        assert "name" in v


def test_project_issue_timeline(mcp, project_key):
    jql = f'project = "{project_key}" ORDER BY created ASC'
    fields = "summary,status,assignee,created,duedate,resolutiondate,fixVersions"
    res = mcp.call_json("jira_search",
                        {"jql": jql, "fields": fields, "limit": 20})
    issues = _issues_of(res)
    assert isinstance(issues, list)
    if not issues:
        pytest.skip(f"project {project_key} has no issues visible to this account")
    # every issue must carry a key and a creation timestamp (the timeline anchor)
    for it in issues:
        assert it.get("key")
        assert _field(it, "created"), f"{it.get('key')} missing 'created'"


# --- TEST 2: Confluence page, two latest versions ------------------------
def test_read_two_latest_versions(mcp, page_id):
    current = mcp.call_json(
        "confluence_get_page",
        {"page_id": page_id, "include_metadata": True,
         "convert_to_markdown": True})
    n = _find_version_number(current)
    assert n is not None, "could not determine current version number"

    if n < 2:
        pytest.skip(f"page {page_id} has only one version (v{n})")

    latest = mcp.call("confluence_get_page_history",
                      {"page_id": page_id, "version": n,
                       "convert_to_markdown": True})
    previous = mcp.call("confluence_get_page_history",
                        {"page_id": page_id, "version": n - 1,
                         "convert_to_markdown": True})

    assert latest.strip(), f"v{n} returned empty content"
    assert previous.strip(), f"v{n-1} returned empty content"
    # two distinct versions must not be byte-identical
    assert latest != previous, "v{} and v{} content is identical".format(n, n - 1)


def test_diff_between_two_latest_versions(mcp, page_id):
    current = mcp.call_json(
        "confluence_get_page",
        {"page_id": page_id, "include_metadata": True})
    n = _find_version_number(current)
    assert n is not None
    if n < 2:
        pytest.skip(f"page {page_id} has only one version (v{n})")

    diff = mcp.call("confluence_get_page_diff",
                    {"page_id": page_id, "from_version": n - 1, "to_version": n})
    assert diff.strip(), "diff returned empty"
