# Connecting to the remote read-only Atlassian MCP server

The Atlassian MCP server now runs in Azure as a remote streamable-http endpoint behind GitHub OAuth (see `wiki/azure-deployment.md` for how it is deployed). This documents how to connect clients to it. The endpoint is:

```
https://<your-container-app-fqdn>/mcp
```

Authentication is GitHub OAuth: the first time a client connects it opens a browser, you sign in to GitHub and authorize the OAuth app, and the token is cached for later sessions. Everything reachable is read-only — the server exposes only the read allowlist and runs with `READ_ONLY_MODE=true`.

## Claude Desktop (primary)

Claude Desktop's native custom connectors speak the MCP OAuth flow directly, and our auth-proxy advertises that flow (dynamic client registration + PKCE), so no bridge tool is needed.

1. Open Claude Desktop > Settings > Connectors > Add custom connector.
2. Name it something like `VNPay Atlassian`, and set the URL to `https://<your-container-app-fqdn>/mcp`.
3. Save. Claude Desktop discovers the OAuth metadata and opens a browser for GitHub sign-in. Authorize the app.
4. The connector's read-only Jira/Confluence tools appear in Claude Desktop. The token is cached, so later launches do not re-prompt.

If your GitHub account is not on the server's `ALLOWED_GITHUB_USERS` list (when one is configured), the connection authenticates but tool calls are rejected — ask the deployment owner to add your GitHub login.

### Fallback: the mcp-remote bridge

Older Claude Desktop builds that cannot dial a remote MCP URL can bridge through `mcp-remote`. This needs Node.js on Windows so `npx` is available. Add to `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "vnpay-atlassian": {
      "command": "cmd",
      "args": [
        "/c", "npx", "-y", "mcp-remote",
        "https://<your-container-app-fqdn>/mcp",
        "--transport", "http-only"
      ]
    }
  }
}
```

`mcp-remote` runs the OAuth flow in your browser via a localhost callback and caches the token under `%USERPROFILE%\.mcp-auth`. Wrap the call in `cmd /c` so Claude Desktop can resolve `npx.cmd`. To re-authenticate from scratch, delete `%USERPROFILE%\.mcp-auth` and restart.

## Claude Code (secondary)

Claude Code supports remote HTTP MCP servers natively, including the OAuth flow:

```bash
claude mcp add --transport http vnpay-atlassian https://<your-container-app-fqdn>/mcp
```

On first use it runs the GitHub OAuth flow in your browser. Confirm it connected with `/mcp` (or `claude mcp get vnpay-atlassian`). If discovery needs a nudge (for example the well-known endpoints are routed oddly), point Claude Code at the authorization-server metadata explicitly with `--authServerMetadataUrl https://<fqdn>/.well-known/oauth-authorization-server`.

## What you can do once connected

The read-only tools for planning and analysis are unchanged from the stdio deployment: Jira timeline/effort/assignment reads (`jira_search`, `jira_get_issue`, `jira_get_project_issues`, sprint/board/worklog/version/changelog lookups) and Confluence wiki + versioning reads (`confluence_search`, `confluence_get_page`, `confluence_get_page_history`, `confluence_get_page_diff`, and so on). There are no write tools — by design.

## Troubleshooting

- Browser never opens / auth loops: confirm the GitHub OAuth app's callback URL is exactly `https://<fqdn>/auth/callback` and that `PUBLIC_BASE_URL` on the app equals `https://<fqdn>`.
- 401 / not authorized after login: your GitHub login may not be on `ALLOWED_GITHUB_USERS`. Check the auth-proxy logs: `az containerapp logs show -g <rg> -n <app> --container auth-proxy --tail 50`.
- Tools missing or a write tool expected: that is intentional — only the `ENABLED_TOOLS` read allowlist is loaded and `READ_ONLY_MODE=true`.
- Endpoint unreachable: confirm the revision is `Running`/`Healthy` (`az containerapp revision list`) and that ingress is external.
