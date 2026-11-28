#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports
<#
.SYNOPSIS
Compromised workload identity triage (read-only example).

.DESCRIPTION
Purpose: An app or agent flagged as risky can act without a user, so its permissions, credentials and recent activity need checking together.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-workload-identity-triage

Scopes (delegated, read-only): IdentityRiskyServicePrincipal.Read.All, Application.Read.All, AuditLog.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Security Reader for risky service principals. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Microsoft Entra Workload ID Premium for risky service principals; Entra ID P1 or P2 for sign-in logs.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not confirm compromise, dismiss risk, disable the app or remove credentials.
- Service principal sign-ins come from the beta endpoint.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER AppId
One app to look at. Without it the script looks at every service principal flagged at risk.

.PARAMETER Days
How far back to read sign-ins and changes. Default 7.

.PARAMETER MaxSignIns
Upper limit on sign-in rows per app. Default 500.

.EXAMPLE
./workload-identity-triage.ps1 -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-workload-identity-triage
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [string]$AppId,
    [int]$Days = 7,
    [int]$MaxSignIns = 500
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('IdentityRiskyServicePrincipal.Read.All', 'Application.Read.All', 'AuditLog.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('workload-identity-triage-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$since = Get-UtcStamp -DaysAgo $Days

# Step 1: GET /identityProtection/riskyServicePrincipals
$risky = @(Invoke-ReadStep '1-risky-service-principals' {
    Get-MgRiskyServicePrincipal -All | Select-Object Id, AppId, DisplayName, RiskLevel, RiskState, RiskDetail, RiskLastUpdatedDateTime, ServicePrincipalType
})
$appIds = if ($AppId) { @($AppId) } else { @($risky | Where-Object RiskState -ne 'dismissed' | ForEach-Object AppId | Sort-Object -Unique) }

# Step 2: GET /servicePrincipals(appId='{appId}')
$sps = @(Invoke-ReadStep '2-service-principals' {
    foreach ($a in $appIds) {
        Get-MgServicePrincipal -Filter "appId eq '$a'" -Property id,appId,displayName,accountEnabled,appOwnerOrganizationId,passwordCredentials,keyCredentials |
            Select-Object Id, AppId, DisplayName, AccountEnabled, AppOwnerOrganizationId,
                @{n = 'Secrets'; e = { @($_.PasswordCredentials).Count } }, @{n = 'Certificates'; e = { @($_.KeyCredentials).Count } }
    }
})

# Step 3: GET /servicePrincipals/{id}/appRoleAssignments
$null = Invoke-ReadStep '3-app-permissions' {
    foreach ($s in $sps) {
        Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $s.Id -All |
            Select-Object @{n = 'App'; e = { $s.DisplayName } }, ResourceDisplayName, AppRoleId, CreatedDateTime
    }
}

# Step 4: GET /beta/auditLogs/signIns?$filter=signInEventTypes/any(t: t eq 'servicePrincipal') and appId eq '{appId}'
$null = Invoke-ReadStep '4-sign-ins' {
    foreach ($a in $appIds) {
        $filter = "signInEventTypes/any(t: t eq 'servicePrincipal') and appId eq '$a' and createdDateTime ge $since"
        Get-GraphCollection -Uri "$graph/beta/auditLogs/signIns?`$filter=$([uri]::EscapeDataString($filter))" -MaxItems $MaxSignIns |
            Select-Object @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }, @{n = 'appId'; e = { Get-Field $_ 'appId' } },
                @{n = 'resourceDisplayName'; e = { Get-Field $_ 'resourceDisplayName' } }, @{n = 'ipAddress'; e = { Get-Field $_ 'ipAddress' } },
                @{n = 'country'; e = { Get-Field (Get-Field $_ 'location') 'countryOrRegion' } }, @{n = 'errorCode'; e = { Get-Field (Get-Field $_ 'status') 'errorCode' } }
    }
}

# Step 5: GET /auditLogs/directoryAudits (changes that touched these service principals)
$spIds = @($sps | ForEach-Object Id)
$null = Invoke-ReadStep '5-directory-changes' {
    Get-MgAuditLogDirectoryAudit -Filter "activityDateTime ge $since" -All |
        Where-Object { @($_.TargetResources.Id | Where-Object { $spIds -contains $_ }).Count } |
        Select-Object ActivityDateTime, ActivityDisplayName, Category, Result,
            @{n = 'InitiatedBy'; e = { if ($_.InitiatedBy.User.UserPrincipalName) { $_.InitiatedBy.User.UserPrincipalName } else { $_.InitiatedBy.App.DisplayName } } },
            @{n = 'Targets'; e = { ($_.TargetResources.DisplayName | Where-Object { $_ }) -join ';' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
