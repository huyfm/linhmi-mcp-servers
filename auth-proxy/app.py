#!/usr/bin/env python3
"""GitHub-OAuth gateway in front of the read-only Atlassian MCP server.

This is the ONLY custom code in the deployment. It is an authentication gateway
only: it terminates GitHub OAuth for incoming MCP clients (Claude Desktop /
Claude Code) and transparently proxies the authenticated session to the
unchanged `mcp-atlassian` container running next to it on localhost.

It deliberately does NOT talk to Jira/Confluence itself and adds NO write path.
Read-only is still enforced where it always was: on the `mcp-atlassian`
container, by READ_ONLY_MODE=true plus the ENABLED_TOOLS allowlist. This proxy
cannot loosen that.

How the OAuth works (FastMCP's GitHubProvider):
  * GitHub OAuth apps do not support dynamic client registration (DCR), but MCP
    clients expect a DCR/PKCE-compliant authorization server. GitHubProvider
    bridges that: it presents the spec endpoints
    (/.well-known/oauth-authorization-server, /.well-known/oauth-protected-resource,
    /register, /authorize, /token) to the client while holding ONE pre-registered
    GitHub OAuth app upstream. So Claude Desktop's native custom connector and the
    mcp-remote bridge both work against this server with a browser GitHub login.

Env (see .env.example):
  GITHUB_OAUTH_CLIENT_ID / GITHUB_OAUTH_CLIENT_SECRET  GitHub OAuth app creds
  PUBLIC_BASE_URL        the externally reachable https URL of THIS proxy
                         (the GitHub OAuth app callback must be PUBLIC_BASE_URL + /auth/callback)
  BACKEND_MCP_URL        where mcp-atlassian listens (default http://localhost:9000/mcp)
  PROXY_HOST / PROXY_PORT  bind for this proxy (default 0.0.0.0:8000)
  ALLOWED_GITHUB_USERS   optional comma-separated GitHub logins allowed through
                         (empty = any user who completes GitHub OAuth on this app)
  AUTH_DISABLED          set to "true" for LOCAL dev only — skips GitHub entirely
"""

from __future__ import annotations

import os
import sys

from fastmcp import FastMCP
from fastmcp.server.proxy import ProxyClient
from fastmcp.client.transports import StreamableHttpTransport
# Private mcp helper, but stable for our pinned fastmcp/mcp versions. It builds the
# httpx client used to reach the backend, preserving MCP defaults (follow_redirects,
# SSE-friendly timeouts) that we must not lose when customizing the factory below.
from mcp.shared._httpx_utils import create_mcp_http_client


def _env(name: str, default: str | None = None, *, required: bool = False) -> str | None:
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"auth-proxy: required env var {name} is not set")
    return val


BACKEND_MCP_URL = _env("BACKEND_MCP_URL", "http://localhost:9000/mcp")
PROXY_HOST = _env("PROXY_HOST", "0.0.0.0")
PROXY_PORT = int(_env("PROXY_PORT", "8000"))
MCP_PATH = _env("STREAMABLE_HTTP_PATH", "/mcp")
AUTH_DISABLED = (_env("AUTH_DISABLED", "false") or "").lower() == "true"
ALLOWED_USERS = {
    u.strip().lower()
    for u in (_env("ALLOWED_GITHUB_USERS", "") or "").split(",")
    if u.strip()
}


def build_auth():
    """Construct the GitHub OAuth provider, or None when auth is disabled (dev)."""
    if AUTH_DISABLED:
        print("auth-proxy: AUTH_DISABLED=true -- NO authentication (local dev only)",
              file=sys.stderr)
        return None

    # Imported lazily so the dev no-auth path doesn't require the provider.
    from fastmcp.server.auth.providers.github import GitHubProvider

    class PublicClientGitHubProvider(GitHubProvider):
        """Treat every DCR-registered MCP client as a PUBLIC (PKCE-only) client.

        FastMCP's OAuthProxy issues *confidential* clients for DCR registrations
        that don't explicitly ask to be public: token_endpoint_auth_method =
        client_secret_post with a generated secret. Claude Code registers as a
        public client and works; Claude.ai / Claude Desktop do not, so their token
        exchange is rejected at /token with 401 "Client secret is required" (in
        this pinned fastmcp/mcp the confidential path fails even when the correct
        secret is sent). We force every client to "none" at lookup time so the
        token handler skips the client-secret check.

        This is safe: the exchange is still protected by PKCE (code_verifier), and
        access is still gated by GitHub OAuth plus the ALLOWED_GITHUB_USERS
        allowlist. The dropped client secret was unused anyway.
        """

        async def get_client(self, client_id):
            client = await super().get_client(client_id)
            if client is not None:
                client.token_endpoint_auth_method = "none"
                client.client_secret = None
            return client

    return PublicClientGitHubProvider(
        client_id=_env("GITHUB_OAUTH_CLIENT_ID", required=True),
        client_secret=_env("GITHUB_OAUTH_CLIENT_SECRET", required=True),
        # Public https URL of THIS proxy. GitHubProvider derives the OAuth
        # callback from it; register PUBLIC_BASE_URL + "/auth/callback" on the
        # GitHub OAuth app.
        base_url=_env("PUBLIC_BASE_URL", required=True),
    )


def attach_user_allowlist(server: FastMCP) -> None:
    """Reject authenticated GitHub users not on ALLOWED_GITHUB_USERS.

    GitHub OAuth apps can't restrict who consents, so any GitHub account could
    complete the flow. When ALLOWED_GITHUB_USERS is set we additionally gate on
    the login. If it's empty, any user who authenticates is allowed through.

    NOTE: the exact claim key holding the GitHub login is FastMCP-version
    specific. We probe the common locations and FAIL CLOSED (deny) when an
    allowlist is configured but the login can't be resolved -- adjust
    `_login_from_token` if your FastMCP version stores it elsewhere.
    """
    if AUTH_DISABLED or not ALLOWED_USERS:
        return

    from fastmcp.server.middleware import Middleware, MiddlewareContext
    from fastmcp.server.dependencies import get_access_token

    def _login_from_token(token) -> str | None:
        claims = getattr(token, "claims", None) or {}
        for key in ("login", "username", "preferred_username", "github_login"):
            val = claims.get(key)
            if val:
                return str(val).lower()
        # Some providers nest the raw profile under "user"/"profile".
        for nest in ("user", "profile", "github"):
            sub = claims.get(nest) or {}
            if isinstance(sub, dict) and sub.get("login"):
                return str(sub["login"]).lower()
        return None

    class GitHubUserAllowlist(Middleware):
        async def on_request(self, context: MiddlewareContext, call_next):
            token = get_access_token()
            login = _login_from_token(token) if token else None
            if login is None:
                raise PermissionError(
                    "access denied: could not determine GitHub login to check "
                    "against ALLOWED_GITHUB_USERS (see auth-proxy/app.py)"
                )
            if login not in ALLOWED_USERS:
                raise PermissionError(f"access denied: GitHub user '{login}' is not allowed")
            return await call_next(context)

    server.add_middleware(GitHubUserAllowlist())


def _backend_client_factory(headers=None, timeout=None, auth=None):
    """Build the httpx client the proxy uses to reach mcp-atlassian, with the
    inbound ``Authorization`` header STRIPPED.

    FastMCP's proxy transport forwards the caller's HTTP headers to the backend
    (``get_http_headers() | self.headers`` in StreamableHttpTransport). That
    includes the GitHub OAuth bearer this proxy validated. If it reaches
    mcp-atlassian, mcp-atlassian treats it as an *Atlassian* token, ignores its
    env service-account PAT, and fails with "Unable to get current user account
    ID". The backend must authenticate ONLY via its env PAT, so we drop the
    header here -- the single point where the backend client is constructed.
    """
    headers = {k: v for k, v in (headers or {}).items() if k.lower() != "authorization"}
    return create_mcp_http_client(headers=headers, timeout=timeout, auth=auth)


def main() -> None:
    backend = ProxyClient(transport=StreamableHttpTransport(
        url=BACKEND_MCP_URL, httpx_client_factory=_backend_client_factory))
    proxy = FastMCP.as_proxy(backend, name="vnpay-atlassian", auth=build_auth())
    attach_user_allowlist(proxy)

    print(f"auth-proxy: proxying {MCP_PATH} -> {BACKEND_MCP_URL} "
          f"(auth={'OFF' if AUTH_DISABLED else 'GitHub OAuth'}, "
          f"allowlist={'|'.join(sorted(ALLOWED_USERS)) or 'any'})", file=sys.stderr)

    proxy.run(transport="http", host=PROXY_HOST, port=PROXY_PORT, path=MCP_PATH)


if __name__ == "__main__":
    main()
