#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
Least-privilege review of apps' and agents' Graph permissions (read-only example).

.DESCRIPTION
Purpose: Apps and agents often hold far more Graph permission than they use, and every unused permission is attack surface.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-app-permission-review

Scopes (delegated, read-only): Application.Read.All, Directory.Read.All, AgentIdentity.Read.All, AuditLog.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or Cloud Application Administrator. Reports Reader or Security Reader for the sign-in activity report. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID Free for the grants; Entra ID P1 or P2 for the last-used report.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not remove permissions or consent grants.
- Last sign-in comes from the beta servicePrincipalSignInActivities report; Learn says a timestamp alone doesn't prove the sign-in succeeded.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.EXAMPLE
./app-permission-review.ps1

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-app-permission-review
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Application.Read.All', 'Directory.Read.All', 'AgentIdentity.Read.All', 'AuditLog.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('app-permission-review-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$graphAppId = '00000003-0000-0000-c000-000000000000'

# Step 1: GET /servicePrincipals(appId='00000003-0000-0000-c000-000000000000')
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -Property id,appId,displayName,appRoles,oauth2PermissionScopes
$roleName = @{}; foreach ($r in @($graphSp.AppRoles)) { $roleName["$($r.Id)"] = $r.Value }
$null = Invoke-ReadStep '1-graph-service-principal' { $graphSp | Select-Object Id, AppId, DisplayName, @{n = 'AppRoles'; e = { @($_.AppRoles).Count } }, @{n = 'DelegatedScopes'; e = { @($_.Oauth2PermissionScopes).Count } } }

# Service principal names and types, to label the holders
$spInfo = @{}
foreach ($s in Get-MgServicePrincipal -All -Property id,appId,displayName,servicePrincipalType,appOwnerOrganizationId) { $spInfo[$s.Id] = $s }

# Step 4 first, so agents can be marked: GET /servicePrincipals/microsoft.graph.agentIdentity
$agentIds = @{}
$null = Invoke-ReadStep '4-agent-identities' {
    Get-GraphCollection -Uri "$graph/v1.0/servicePrincipals/microsoft.graph.agentIdentity" | ForEach-Object {
        $agentIds[(Get-Field $_ 'id')] = $true
        [pscustomobject]@{ id = Get-Field $_ 'id'; appId = Get-Field $_ 'appId'; displayName = Get-Field $_ 'displayName'; agentIdentityBlueprintId = Get-Field $_ 'agentIdentityBlueprintId' }
    }
}

# Step 2: GET /servicePrincipals(appId='00000003-...')/appRoleAssignedTo (application permissions to Graph)
$appPerms = @(Invoke-ReadStep '2-graph-application-permissions' {
    Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -All | ForEach-Object {
        $holder = $spInfo[$_.PrincipalId]
        [pscustomobject]@{ Holder = $_.PrincipalDisplayName; HolderId = $_.PrincipalId; HolderAppId = $holder.AppId; PrincipalType = $_.PrincipalType
            IsAgent = [bool]$agentIds[$_.PrincipalId]; Permission = $roleName["$($_.AppRoleId)"]; Granted = $_.CreatedDateTime }
    }
})

# Step 3: GET /oauth2PermissionGrants?$filter=resourceId eq '{graphServicePrincipalObjectId}' (delegated permissions to Graph)
$null = Invoke-ReadStep '3-graph-delegated-grants' {
    Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($graphSp.Id)'" -All |
        Select-Object @{n = 'Client'; e = { $spInfo[$_.ClientId].DisplayName } }, ClientId, @{n = 'IsAgent'; e = { [bool]$agentIds[$_.ClientId] } }, ConsentType, PrincipalId, Scope
}

# Step 5: GET /beta/reports/servicePrincipalSignInActivities (last sign-in for each holder)
$null = Invoke-ReadStep '5-last-sign-in' {
    $holders = @($appPerms | ForEach-Object HolderAppId | Where-Object { $_ } | Sort-Object -Unique)
    Get-GraphCollection -Uri "$graph/beta/reports/servicePrincipalSignInActivities" | Where-Object { $holders -contains (Get-Field $_ 'appId') } |
        Select-Object @{n = 'appId'; e = { Get-Field $_ 'appId' } }, @{n = 'lastSignIn'; e = { Get-Field (Get-Field $_ 'lastSignInActivity') 'lastSignInDateTime' } },
            @{n = 'lastAppOnlyAsClient'; e = { Get-Field (Get-Field $_ 'applicationAuthenticationClientSignInActivity') 'lastSignInDateTime' } },
            @{n = 'lastDelegatedAsClient'; e = { Get-Field (Get-Field $_ 'delegatedClientSignInActivity') 'lastSignInDateTime' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
