#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users
<#
.SYNOPSIS
Licence clean-up, including Copilot seats (read-only example).

.DESCRIPTION
Purpose: Licences on disabled, idle or duplicate assignments are money spent for nothing, and Copilot seats are the most expensive to waste.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-licence-cleanup

Scopes (delegated, read-only): LicenseAssignment.Read.All, User.Read.All, AuditLog.Read.All, GroupMember.Read.All, Reports.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or License Administrator plus Reports Reader. Reports Reader or AI Administrator for the Copilot report. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P1 or P2 for sign-in activity.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not remove or reassign licences.
- Remove group-based licences from the group, not the user (step 4).
- Sign-in activity has no data before April 2020 (Learn).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER DaysInactive
Licensed users with no sign-in for this many days are flagged. Default 90.

.EXAMPLE
./licence-cleanup.ps1 -DaysInactive 90

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-licence-cleanup
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$DaysInactive = 90
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('LicenseAssignment.Read.All', 'User.Read.All', 'AuditLog.Read.All', 'GroupMember.Read.All', 'Reports.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('licence-cleanup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)

# Step 1: GET /subscribedSkus (bought against used)
$skuName = @{}
$null = Invoke-ReadStep '1-subscriptions' {
    Get-MgSubscribedSku -All | ForEach-Object {
        $skuName["$($_.SkuId)"] = $_.SkuPartNumber
        [pscustomobject]@{ SkuPartNumber = $_.SkuPartNumber; SkuId = $_.SkuId; Enabled = $_.PrepaidUnits.Enabled; Consumed = $_.ConsumedUnits
            Unused = $_.PrepaidUnits.Enabled - $_.ConsumedUnits; CapabilityStatus = $_.CapabilityStatus }
    }
}

# Step 2: GET /users?$select=id,userPrincipalName,accountEnabled,assignedLicenses,signInActivity (page size 500)
$licensed = @(Get-MgUser -All -PageSize 500 -Property id,userPrincipalName,accountEnabled,assignedLicenses,licenseAssignmentStates,signInActivity | Where-Object { @($_.AssignedLicenses).Count })
$null = Invoke-ReadStep '2-inactive-licensed-users' {
    $licensed | Where-Object { -not $_.SignInActivity.LastSignInDateTime -or $_.SignInActivity.LastSignInDateTime -lt $cutoff } |
        Select-Object Id, UserPrincipalName, AccountEnabled, @{n = 'Licences'; e = { ($_.AssignedLicenses | ForEach-Object { $skuName["$($_.SkuId)"] }) -join ';' } },
            @{n = 'LastSignIn'; e = { $_.SignInActivity.LastSignInDateTime } }, @{n = 'LastNonInteractiveSignIn'; e = { $_.SignInActivity.LastNonInteractiveSignInDateTime } }
}

# Step 3: GET /users?$filter=accountEnabled eq false and assignedLicenses/$count ne 0&$count=true (ConsistencyLevel: eventual)
$null = Invoke-ReadStep '3-disabled-with-licences' {
    Get-MgUser -Filter 'accountEnabled eq false and assignedLicenses/$count ne 0' -CountVariable disabledLicensed -ConsistencyLevel eventual -All -Property id,userPrincipalName,assignedLicenses |
        Select-Object Id, UserPrincipalName, @{n = 'Licences'; e = { ($_.AssignedLicenses | ForEach-Object { $skuName["$($_.SkuId)"] }) -join ';' } }
}

# Step 4: GET /groups/{id} (groups that assign licences, from users' licenseAssignmentStates)
$null = Invoke-ReadStep '4-licensing-groups' {
    $groupIds = @($licensed | ForEach-Object { $_.LicenseAssignmentStates.AssignedByGroup } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($g in $groupIds) {
        Get-MgGroup -GroupId $g -Property id,displayName,assignedLicenses | Select-Object Id, DisplayName,
            @{n = 'Licences'; e = { ($_.AssignedLicenses | ForEach-Object { $skuName["$($_.SkuId)"] }) -join ';' } },
            @{n = 'LicensedMembers'; e = { @($licensed | Where-Object { $_.LicenseAssignmentStates.AssignedByGroup -contains $g }).Count } }
    }
}

# Step 5: GET /copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28') (CSV straight from Microsoft)
try {
    Invoke-MgGraphRequest -Method GET -Uri "$graph/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28')" -OutputFilePath (Join-Path $runFolder '5-copilot-usage-user-detail.csv')
    Write-Information '5-copilot-usage-user-detail.csv written' -InformationAction Continue
} catch { Write-Warning "5-copilot-usage-user-detail: $($_.Exception.Message)" }

Write-Information "Done. Results: $runFolder" -InformationAction Continue
