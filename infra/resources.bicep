// Resource-group-scoped resources for the read-only Atlassian MCP deployment.
// Deployed by main.bicep into the claude-mcp-rg resource group.
//
// Lowest-cost posture: no ACR (auth-proxy comes from public ghcr.io, pulled
// anonymously), no Key Vault / managed identity (secrets are native Container
// Apps secrets), Consumption environment, smallest valid container sizes, and
// scale-to-zero (minReplicas=0) so there is no idle compute cost — usage stays
// within the Consumption free grant. Trade-off: an HTTP cold start on the first
// request after the app has idled down.

@description('Azure region for all resources.')
param location string

@description('Container App name (also the ingress hostname prefix).')
param appName string

@description('Fully-qualified auth-proxy image on public ghcr.io, e.g. ghcr.io/<user>/vnpay-atlassian-auth-proxy:1')
param authProxyImage string

@description('Pinned tag for the community mcp-atlassian image.')
param mcpAtlassianTag string

@description('Self-hosted Jira base URL.')
param jiraUrl string

@description('Self-hosted Confluence base URL.')
param confluenceUrl string

@description('GitHub OAuth app client id (non-secret).')
param githubClientId string

@description('Optional comma-separated GitHub logins allowed through (empty = any authenticated user).')
param allowedGithubUsers string

@description('Read-only tool allowlist passed to mcp-atlassian (ENABLED_TOOLS).')
param enabledTools string

@description('Set "true" only to bring the proxy up WITHOUT GitHub auth (first-pass FQDN discovery / local-style). Never leave true in production.')
param authDisabled string

@secure()
@description('Read-only Jira Personal Access Token.')
param jiraPat string

@secure()
@description('Read-only Confluence Personal Access Token.')
param confluencePat string

@secure()
@description('GitHub OAuth app client secret.')
param githubClientSecret string

// Smallest valid Consumption combo per container: 0.25 vCPU / 0.5 GiB.
// Two containers -> 0.5 vCPU / 1.0 GiB total (an allowed combination).
var cpu = json('0.25')
var memory = '0.5Gi'

// Container Apps secrets reject empty values; substitute a harmless placeholder
// when a secret is not yet provided (e.g. first-pass deploy with auth disabled).
var jiraPatValue = empty(jiraPat) ? 'unset' : jiraPat
var confluencePatValue = empty(confluencePat) ? 'unset' : confluencePat
var githubSecretValue = empty(githubClientSecret) ? 'unset' : githubClientSecret

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'claude-mcp-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    // 30 days is the minimum billable-free retention; ingestion at this volume
    // stays within the monthly free allowance.
    retentionInDays: 30
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${appName}-env'
  location: location
  properties: {
    // No workloadProfiles block -> Consumption-only environment (no standing charge).
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// The public URL is deterministic once the environment exists, so we can inject
// it into the proxy without a second deploy: <appName>.<env default domain>.
var publicBaseUrl = 'https://${appName}.${env.properties.defaultDomain}'

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      secrets: [
        {
          name: 'jira-pat'
          value: jiraPatValue
        }
        {
          name: 'confluence-pat'
          value: confluencePatValue
        }
        {
          name: 'github-client-secret'
          value: githubSecretValue
        }
      ]
    }
    template: {
      // Scale-to-zero: idle the app down to 0 replicas so there is no standing
      // compute cost, keeping usage within the Consumption free grant. An HTTP
      // request cold-starts a single replica (both containers); after the
      // inactivity window it scales back to 0. maxReplicas=1 keeps the
      // single-pod, shared-localhost topology (auth-proxy -> mcp-atlassian).
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [
          {
            name: 'http-scale'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
        ]
      }
      containers: [
        {
          // Public-facing GitHub-OAuth gateway (our code, from public ghcr.io).
          name: 'auth-proxy'
          image: authProxyImage
          resources: {
            cpu: cpu
            memory: memory
          }
          env: [
            {
              name: 'AUTH_DISABLED'
              value: authDisabled
            }
            {
              name: 'BACKEND_MCP_URL'
              value: 'http://localhost:9000/mcp'
            }
            {
              name: 'PUBLIC_BASE_URL'
              value: publicBaseUrl
            }
            {
              name: 'GITHUB_OAUTH_CLIENT_ID'
              value: githubClientId
            }
            {
              name: 'GITHUB_OAUTH_CLIENT_SECRET'
              secretRef: 'github-client-secret'
            }
            {
              name: 'ALLOWED_GITHUB_USERS'
              value: allowedGithubUsers
            }
          ]
        }
        {
          // Unchanged community image, internal only, locked read-only.
          name: 'mcp-atlassian'
          image: 'ghcr.io/sooperset/mcp-atlassian:${mcpAtlassianTag}'
          args: [
            '--transport'
            'streamable-http'
            '--host'
            '0.0.0.0'
            '--port'
            '9000'
          ]
          resources: {
            cpu: cpu
            memory: memory
          }
          env: [
            {
              name: 'JIRA_URL'
              value: jiraUrl
            }
            {
              name: 'CONFLUENCE_URL'
              value: confluenceUrl
            }
            {
              name: 'JIRA_SSL_VERIFY'
              value: 'true'
            }
            {
              name: 'CONFLUENCE_SSL_VERIFY'
              value: 'true'
            }
            {
              name: 'JIRA_PERSONAL_TOKEN'
              secretRef: 'jira-pat'
            }
            {
              name: 'CONFLUENCE_PERSONAL_TOKEN'
              secretRef: 'confluence-pat'
            }
            // Read-only layer 1: globally disable all write operations.
            {
              name: 'READ_ONLY_MODE'
              value: 'true'
            }
            // Read-only layer 2: only read tools are even loaded.
            {
              name: 'ENABLED_TOOLS'
              value: enabledTools
            }
          ]
        }
      ]
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output mcpUrl string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
output callbackUrl string = 'https://${app.properties.configuration.ingress.fqdn}/auth/callback'
