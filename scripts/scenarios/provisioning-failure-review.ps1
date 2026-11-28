#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Reports, Microsoft.Graph.Users
<#
.SYNOPSIS
Provisioning failure review (read-only example).

.DESCRIPTION
Purpose: A failed provisioning run can leave a joiner without access or a leaver still active in a SaaS app, and nobody notices until someone complains.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-provisioning-failure-review

Scopes (delegated, read-only): AuditLog.Read.All, Directory.Read.All, Application.Read.All, User.ReadBasic.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Reports Reader or Security Reader for provisioning logs. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P1 or P2 for provisioning logs.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not restart provisioning jobs or change attribute mappings.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
How far back to look. Default 7.

.PARAMETER MaxRows
Upper limit on provisioning events read. Default 5000.

.EXAMPLE
./provisioning-failure-review.ps1 -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Reports, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-provisioning-failure-review
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7,
    [int]$MaxRows = 5000
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('AuditLog.Read.All', 'Directory.Read.All', 'Application.Read.All', 'User.ReadBasic.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('provisioning-failure-review-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /auditLogs/provisioning?$filter=activityDateTime gt {date} (failures only)
$failures = @(Invoke-ReadStep '1-provisioning-failures' {
    Get-MgAuditLogProvisioning -Filter "activityDateTime gt $since" -Top $MaxRows |
        Where-Object { $_.ProvisioningStatusInfo.Status -eq 'failure' } |
        Select-Object ActivityDateTime, JobId, CycleId, ProvisioningAction,
            @{n = 'Reason'; e = { $_.ProvisioningStatusInfo.ErrorInformation.Reason } }, @{n = 'ErrorCode'; e = { $_.ProvisioningStatusInfo.ErrorInformation.ErrorCode } },
            @{n = 'Source'; e = { $_.SourceIdentity.DisplayName } }, @{n = 'Target'; e = { $_.TargetIdentity.DisplayName } },
            @{n = 'TargetId'; e = { $_.TargetIdentity.Id } }, @{n = 'ServicePrincipalId'; e = { $_.ServicePrincipal.Id } }, @{n = 'App'; e = { $_.ServicePrincipal.DisplayName } }
})

# Step 2: GET /servicePrincipals/{id}
$spIds = @($failures | ForEach-Object ServicePrincipalId | Where-Object { $_ } | Sort-Object -Unique)
$null = Invoke-ReadStep '2-apps' {
    foreach ($id in $spIds) { Get-MgServicePrincipal -ServicePrincipalId $id -Property id,appId,displayName,accountEnabled | Select-Object Id, AppId, DisplayName, AccountEnabled }
}

# Step 3: GET /users/{id} (failed objects that are users in this tenant)
$null = Invoke-ReadStep '3-users' {
    foreach ($id in $failures | ForEach-Object TargetId | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 200) {
        try { Get-MgUser -UserId $id -Property id,displayName,userPrincipalName,accountEnabled | Select-Object Id, DisplayName, UserPrincipalName, AccountEnabled } catch { Write-Verbose "Not a user here: $id" }
    }
}

# Step 4: GET /auditLogs/directoryAudits (changes to the provisioning apps)
$null = Invoke-ReadStep '4-app-changes' {
    Get-MgAuditLogDirectoryAudit -Filter "activityDateTime ge $since" -All |
        Where-Object { @($_.TargetResources.Id | Where-Object { $spIds -contains $_ }).Count } |
        Select-Object ActivityDateTime, ActivityDisplayName, Result, @{n = 'Targets'; e = { ($_.TargetResources.DisplayName | Where-Object { $_ }) -join ';' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
