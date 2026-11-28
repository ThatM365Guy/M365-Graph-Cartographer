#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Devices.ServiceAnnouncement, Microsoft.Graph.Security
<#
.SYNOPSIS
Weekly posture and change review (read-only example).

.DESCRIPTION
Purpose: A short weekly check: where Secure Score can still improve, which Microsoft changes need action, and which incidents are open.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-posture-change-review

Scopes (delegated, read-only): SecurityEvents.Read.All, ServiceMessage.Read.All, ServiceHealth.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Security Reader for Secure Score; Message Center Reader and Service Support Administrator (or Global Reader) for the admin center. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: No licence is stated on these API pages. Delegated calls to service health and the Message centre need an admin role.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not change control states or mark messages read.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
Messages and issues changed in this many days are kept. Default 7.

.EXAMPLE
./posture-change-review.ps1 -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Devices.ServiceAnnouncement, Microsoft.Graph.Security -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-posture-change-review
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('SecurityEvents.Read.All', 'ServiceMessage.Read.All', 'ServiceHealth.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('posture-change-review-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)

# Step 1: GET /security/secureScores?$top=1 (and the week before, for comparison)
$scores = @(Invoke-ReadStep '1-secure-score' {
    Get-MgSecuritySecureScore -Top 8 | Select-Object CreatedDateTime, CurrentScore, MaxScore, @{n = 'Percent'; e = { if ($_.MaxScore) { [math]::Round(100 * $_.CurrentScore / $_.MaxScore, 1) } } }, ActiveUserCount, LicensedUserCount
})
$latest = Get-MgSecuritySecureScore -Top 1

# Step 2: GET /security/secureScoreControlProfiles (with today's score for each control)
$controlScore = @{}; foreach ($c in @($latest.ControlScores)) { $controlScore[$c.ControlName] = $c.Score }
$null = Invoke-ReadStep '2-controls' {
    Get-MgSecuritySecureScoreControlProfile -All | Where-Object { -not $_.Deprecated } |
        Select-Object Id, Title, ControlCategory, MaxScore, @{n = 'CurrentScore'; e = { $controlScore[$_.Id] } }, Rank, Tier, ImplementationCost, UserImpact, LastModifiedDateTime
}

# Step 3: GET /admin/serviceAnnouncement/messages
$null = Invoke-ReadStep '3-message-centre' {
    Get-MgServiceAnnouncementMessage -All | Where-Object { $_.LastModifiedDateTime -ge $cutoff } |
        Select-Object Id, Title, Category, Severity, IsMajorChange, StartDateTime, ActionRequiredByDateTime, LastModifiedDateTime, @{n = 'Services'; e = { ($_.Services) -join ';' } }
}

# Step 4: GET /admin/serviceAnnouncement/issues
$null = Invoke-ReadStep '4-service-health' {
    Get-MgServiceAnnouncementIssue -All | Where-Object { $_.LastModifiedDateTime -ge $cutoff -or -not $_.IsResolved } |
        Select-Object Id, Title, Service, Feature, Status, Classification, IsResolved, StartDateTime, LastModifiedDateTime
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
