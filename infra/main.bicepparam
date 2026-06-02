// Parameter values for main.bicep, sourced from environment variables so the
// same .env that configures the containers also drives the deployment. Secrets
// never live in this file -- they are read from the environment at deploy time.
//
// scripts/deploy-azure.sh exports your .env before invoking:
//   az deployment sub create --location $AZURE_REGION \
//     --template-file infra/main.bicep --parameters infra/main.bicepparam

using './main.bicep'

param location = readEnvironmentVariable('AZURE_REGION', 'southeastasia')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', 'claude-mcp-rg')
param appName = readEnvironmentVariable('AZURE_CONTAINERAPP', 'vnpay-atlassian-mcp')

param ghcrUser = readEnvironmentVariable('GHCR_USER')
param authProxyImageName = readEnvironmentVariable('AUTH_PROXY_IMAGE', 'vnpay-atlassian-auth-proxy')
param authProxyTag = readEnvironmentVariable('AUTH_PROXY_TAG', '1')
param mcpAtlassianTag = readEnvironmentVariable('MCP_ATLASSIAN_TAG', 'latest')

param jiraUrl = readEnvironmentVariable('JIRA_URL')
param confluenceUrl = readEnvironmentVariable('CONFLUENCE_URL')

param githubClientId = readEnvironmentVariable('GITHUB_OAUTH_CLIENT_ID', '')
param allowedGithubUsers = readEnvironmentVariable('ALLOWED_GITHUB_USERS', '')
param enabledTools = readEnvironmentVariable('ENABLED_TOOLS')

// "true" only on a first FQDN-discovery pass; the deploy script flips this on
// automatically while the GitHub OAuth creds are still placeholders.
param authDisabled = readEnvironmentVariable('AUTH_DISABLED', 'false')

param jiraPat = readEnvironmentVariable('JIRA_PERSONAL_TOKEN', '')
param confluencePat = readEnvironmentVariable('CONFLUENCE_PERSONAL_TOKEN', '')
param githubClientSecret = readEnvironmentVariable('GITHUB_OAUTH_CLIENT_SECRET', '')
