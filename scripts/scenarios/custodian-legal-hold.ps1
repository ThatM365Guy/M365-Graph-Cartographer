#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Security
<#
.SYNOPSIS
Legal hold on a departing custodian (read-only example).

.DESCRIPTION
Purpose: If a leaver may be part of litigation, their mailbox and files must be preserved before anything is removed.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-custodian-legal-hold

Scopes (delegated, read-only): eDiscovery.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: eDiscovery Manager (a Purview role group, not an Entra role).
Licence: Microsoft 365 E3 for cases, custodians, searches and holds with delegated calls. E5 or an equivalent eDiscovery add-on for review sets and app-only calls.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not create a case, add custodians, place holds, run estimates or add to review sets: every step of this scenario changes data, so this script leaves it out.
- Instead it reports what already exists: cases, custodians and their hold status, holds (beta), searches and review sets.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER CaseName
Only cases whose name contains this text. Default: every case.

.EXAMPLE
./custodian-legal-hold.ps1 -CaseName 'Leaver'

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Security -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-custodian-legal-hold
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [string]$CaseName
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('eDiscovery.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('custodian-legal-hold-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Read-only overview of the cases this scenario creates.
$cases = @(Invoke-ReadStep '1-cases' {
    Get-MgSecurityCaseEdiscoveryCase -All | Where-Object { -not $CaseName -or $_.DisplayName -like "*$CaseName*" } |
        Select-Object Id, DisplayName, Status, CreatedDateTime, LastModifiedDateTime
})

# Step 2 (read): GET /security/cases/ediscoveryCases/{id}/custodians
$null = Invoke-ReadStep '2-custodians' {
    foreach ($c in $cases) {
        Get-MgSecurityCaseEdiscoveryCaseCustodian -EdiscoveryCaseId $c.Id -All |
            Select-Object @{n = 'Case'; e = { $c.DisplayName } }, DisplayName, Email, Status, HoldStatus, AcknowledgedDateTime, CreatedDateTime
    }
}

# Step 3 (read): holds are beta only in $metadata (GET /beta/security/cases/ediscoveryCases/{id}/legalHolds)
$null = Invoke-ReadStep '3-holds-beta' {
    foreach ($c in $cases) {
        Get-GraphCollection -Uri "$graph/beta/security/cases/ediscoveryCases/$($c.Id)/legalHolds" |
            Select-Object @{n = 'Case'; e = { $c.DisplayName } }, @{n = 'displayName'; e = { Get-Field $_ 'displayName' } },
                @{n = 'status'; e = { Get-Field $_ 'status' } }, @{n = 'isEnabled'; e = { Get-Field $_ 'isEnabled' } }
    }
}

# Step 4 (read): GET /security/cases/ediscoveryCases/{id}/searches
$null = Invoke-ReadStep '4-searches' {
    foreach ($c in $cases) {
        Get-MgSecurityCaseEdiscoveryCaseSearch -EdiscoveryCaseId $c.Id -All |
            Select-Object @{n = 'Case'; e = { $c.DisplayName } }, DisplayName, ContentQuery, CreatedDateTime, LastModifiedDateTime
    }
}

# Step 5 (read): GET /security/cases/ediscoveryCases/{id}/reviewSets
$null = Invoke-ReadStep '5-review-sets' {
    foreach ($c in $cases) {
        Get-MgSecurityCaseEdiscoveryCaseReviewSet -EdiscoveryCaseId $c.Id -All | Select-Object @{n = 'Case'; e = { $c.DisplayName } }, DisplayName, CreatedDateTime
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
