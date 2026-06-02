// Subscription-scoped entry point: creates the claude-mcp-rg resource group and
// deploys all resources into it. Deploy with:
//   az deployment sub create --location <region> --template-file infra/main.bicep --parameters infra/main.bicepparam
// (scripts/deploy-azure.sh wraps this and builds/pushes the auth-proxy image first.)

targetScope = 'subscription'

@description('Azure region for the resource group and all resources.')
param location string = 'southeastasia'

@description('Resource group that holds everything (per project convention).')
param resourceGroupName string = 'claude-mcp-rg'

@description('Container App name (also the ingress hostname prefix).')
param appName string = 'vnpay-atlassian-mcp'

// auth-proxy image is composed from these so the ghcr user lives in one place.
@description('Your GitHub username/org that owns the public ghcr package.')
param ghcrUser string

@description('auth-proxy image repository name on ghcr.io.')
param authProxyImageName string = 'vnpay-atlassian-auth-proxy'

@description('auth-proxy image tag.')
param authProxyTag string = '1'

@description('Pinned tag for the community mcp-atlassian image.')
param mcpAtlassianTag string = 'latest'

@description('Self-hosted Jira base URL.')
param jiraUrl string

@description('Self-hosted Confluence base URL.')
param confluenceUrl string

@description('GitHub OAuth app client id (non-secret). Leave empty on a first auth-disabled pass.')
param githubClientId string = ''

@description('Optional comma-separated GitHub logins allowed through (empty = any authenticated user).')
param allowedGithubUsers string = ''

@description('Read-only tool allowlist passed to mcp-atlassian (ENABLED_TOOLS).')
param enabledTools string

@description('Set "true" only for a first auth-disabled pass to discover the FQDN. Never leave true in production.')
param authDisabled string = 'false'

@secure()
@description('Read-only Jira Personal Access Token.')
param jiraPat string = ''

@secure()
@description('Read-only Confluence Personal Access Token.')
param confluencePat string = ''

@secure()
@description('GitHub OAuth app client secret.')
param githubClientSecret string = ''

var authProxyImage = 'ghcr.io/${ghcrUser}/${authProxyImageName}:${authProxyTag}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module resources 'resources.bicep' = {
  name: 'mcp-resources'
  scope: rg
  params: {
    location: location
    appName: appName
    authProxyImage: authProxyImage
    mcpAtlassianTag: mcpAtlassianTag
    jiraUrl: jiraUrl
    confluenceUrl: confluenceUrl
    githubClientId: githubClientId
    allowedGithubUsers: allowedGithubUsers
    enabledTools: enabledTools
    authDisabled: authDisabled
    jiraPat: jiraPat
    confluencePat: confluencePat
    githubClientSecret: githubClientSecret
  }
}

output fqdn string = resources.outputs.fqdn
output mcpUrl string = resources.outputs.mcpUrl
output callbackUrl string = resources.outputs.callbackUrl
