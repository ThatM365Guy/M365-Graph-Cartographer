#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
Agent identity governance (read-only example).

.DESCRIPTION
Purpose: AI agents now have their own identities; they need an owner, least privilege, Conditional Access and monitoring like any workforce identity.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-agent-identity-governance

Scopes (delegated, read-only): AgentIdentityBlueprint.Read.All, AgentIdentity.Read.All, Policy.Read.All, Directory.Read.All, AuditLog.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Agent ID Administrator (Learn: needed by delegated callers who don't own the agent identities). Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Microsoft Agent 365 (in Microsoft 365 E7) plus Entra ID P1 for Conditional Access on agents. Drifting; checked 16 Nov 2026.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not disable agents, remove grants or change Conditional Access.
- Agent sign-ins come from the beta endpoint (the agent property is beta only).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
How far back to read agent sign-ins. Default 7.

.PARAMETER MaxSignIns
Upper limit on sign-in rows. Default 1000.

.EXAMPLE
./agent-identity-governance.ps1 -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-agent-identity-governance
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7,
    [int]$MaxSignIns = 1000
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('AgentIdentityBlueprint.Read.All', 'AgentIdentity.Read.All', 'Policy.Read.All', 'Directory.Read.All', 'AuditLog.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('agent-identity-governance-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$null = New-Item -ItemType Directory -Path $runFolder -Force
$graph = 'https://graph.microsoft.com'

function Get-Field {
    # Reads a property that may be missing (JSON from Invoke-MgGraphRequest, or AdditionalProperties).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $extra = $Object.PSObject.Properties['AdditionalProperties']
    if ($extra -and $extra.Value -is [System.Collections.IDictionary] -and $extra.Value.Contains($Name)) { return $extra.Value[$Name] }
    return $null
}

function Get-GraphCollection {
    # Follows @odata.nextLink through a GET collection. GET only.
    param([Parameter(Mandatory)][string]$Uri, [hashtable]$Headers = @{}, [int]$MaxItems = 0)
    $next = $Uri
    $count = 0
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers -OutputType PSObject
        foreach ($item in @(Get-Field $page 'value')) {
            if ($null -eq $item) { continue }
            $item
            $count++
            if ($MaxItems -gt 0 -and $count -ge $MaxItems) { return }
        }
        $next = Get-Field $page '@odata.nextLink'
    }
}

function Invoke-ReadStep {
    # Runs one read-only step, writes its rows to <runFolder>\<Name>.csv and returns them.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        $rows = @(& $Body)
    } catch {
        Write-Warning "${Name}: $($_.Exception.Message)"
        return
    }
    $path = Join-Path $runFolder "$Name.csv"
    if ($rows.Count) { $rows | Export-Csv -Path $path -NoTypeInformation -Encoding utf8 }
    Write-Information ('{0,-44} {1,7} rows' -f $Name, $rows.Count) -InformationAction Continue
    return $rows
}

function Write-Skip {
    param([string]$Text)
    Write-Information "Skipped: $Text" -InformationAction Continue
}

function Get-UtcStamp {
    param([int]$DaysAgo = 0)
    (Get-Date).ToUniversalTime().AddDays(-$DaysAgo).ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# Step 1: GET /applications/microsoft.graph.agentIdentityBlueprint
$null = Invoke-ReadStep '1-agent-blueprints' {
    Get-GraphCollection -Uri "$graph/v1.0/applications/microsoft.graph.agentIdentityBlueprint" |
        Select-Object @{n = 'id'; e = { Get-Field $_ 'id' } }, @{n = 'appId'; e = { Get-Field $_ 'appId' } }, @{n = 'displayName'; e = { Get-Field $_ 'displayName' } },
            @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }
}

# Step 2: GET /servicePrincipals/microsoft.graph.agentIdentity
$agents = @(Invoke-ReadStep '2-agent-identities' {
    Get-GraphCollection -Uri "$graph/v1.0/servicePrincipals/microsoft.graph.agentIdentity" |
        Select-Object @{n = 'id'; e = { Get-Field $_ 'id' } }, @{n = 'appId'; e = { Get-Field $_ 'appId' } }, @{n = 'displayName'; e = { Get-Field $_ 'displayName' } },
            @{n = 'agentIdentityBlueprintId'; e = { Get-Field $_ 'agentIdentityBlueprintId' } }, @{n = 'accountEnabled'; e = { Get-Field $_ 'accountEnabled' } },
            @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }
})

# Step 3: GET /identity/conditionalAccess/policies (who each policy targets, as JSON)
$null = Invoke-ReadStep '3-conditional-access' {
    Get-MgIdentityConditionalAccessPolicy -All | Select-Object Id, DisplayName, State,
        @{n = 'Users'; e = { $_.Conditions.Users | ConvertTo-Json -Depth 6 -Compress } },
        @{n = 'ClientApplications'; e = { $_.Conditions.ClientApplications | ConvertTo-Json -Depth 6 -Compress } },
        @{n = 'GrantControls'; e = { ($_.GrantControls.BuiltInControls) -join ';' } }
}

# Step 4: GET /servicePrincipals/{id}/oauth2PermissionGrants
$null = Invoke-ReadStep '4-agent-delegated-grants' {
    foreach ($a in $agents) {
        Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $a.id -All |
            Select-Object @{n = 'Agent'; e = { $a.displayName } }, ConsentType, PrincipalId, ResourceId, Scope
    }
}

# Step 5: GET /beta/auditLogs/signIns?$filter=... agent/agentType eq 'AgentIdentity'
$null = Invoke-ReadStep '5-agent-sign-ins' {
    $filter = "signInEventTypes/any(t: t eq 'servicePrincipal') and agent/agentType eq 'AgentIdentity' and createdDateTime ge $(Get-UtcStamp -DaysAgo $Days)"
    Get-GraphCollection -Uri "$graph/beta/auditLogs/signIns?`$filter=$([uri]::EscapeDataString($filter))" -MaxItems $MaxSignIns |
        Select-Object @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }, @{n = 'appId'; e = { Get-Field $_ 'appId' } },
            @{n = 'servicePrincipalName'; e = { Get-Field $_ 'servicePrincipalName' } }, @{n = 'resourceDisplayName'; e = { Get-Field $_ 'resourceDisplayName' } },
            @{n = 'ipAddress'; e = { Get-Field $_ 'ipAddress' } }, @{n = 'errorCode'; e = { Get-Field (Get-Field $_ 'status') 'errorCode' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
