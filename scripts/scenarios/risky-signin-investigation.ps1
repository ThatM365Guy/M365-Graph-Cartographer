#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports
<#
.SYNOPSIS
Risky sign-in investigation (read-only example).

.DESCRIPTION
Purpose: A risk detection is a lead, not a verdict: tie it to the sign-in behind it and to any change the attacker may have made since.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-risky-signin-investigation

Scopes (delegated, read-only): IdentityRiskEvent.Read.All, IdentityRiskyUser.Read.All, AuditLog.Read.All, UserAuthenticationMethod.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Security Reader for risk data; Authentication Administrator or Global Reader for methods. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P1 or P2 for risk detections; P2 for full risky user data.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not dismiss risk, confirm compromise, reset passwords or change methods.
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

.PARAMETER UserPrincipalName
Only this user. Default: every user with a risk detection.

.PARAMETER MaxDetections
Detections followed up in steps 3 to 5. Default 25.

.EXAMPLE
./risky-signin-investigation.ps1 -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-risky-signin-investigation
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7,
    [string]$UserPrincipalName,
    [int]$MaxDetections = 25
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('IdentityRiskEvent.Read.All', 'IdentityRiskyUser.Read.All', 'AuditLog.Read.All', 'UserAuthenticationMethod.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('risky-signin-investigation-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
$since = Get-UtcStamp -DaysAgo $Days

# Step 1: GET /identityProtection/riskDetections
$detections = @(Invoke-ReadStep '1-risk-detections' {
    Get-MgRiskDetection -All | Where-Object { $_.DetectedDateTime -ge $cutoff -and (-not $UserPrincipalName -or $_.UserPrincipalName -eq $UserPrincipalName) } |
        Sort-Object DetectedDateTime -Descending |
        Select-Object DetectedDateTime, UserPrincipalName, UserId, RiskEventType, RiskLevel, RiskState, DetectionTimingType, Source, IPAddress,
            @{n = 'Country'; e = { $_.Location.CountryOrRegion } }, CorrelationId
})

# Step 2: GET /identityProtection/riskyUsers
$null = Invoke-ReadStep '2-risky-users' {
    Get-MgRiskyUser -All | Where-Object { $_.RiskState -in @('atRisk', 'confirmedCompromised') -and (-not $UserPrincipalName -or $_.UserPrincipalName -eq $UserPrincipalName) } |
        Select-Object Id, UserPrincipalName, RiskLevel, RiskState, RiskDetail, RiskLastUpdatedDateTime
}

$follow = @($detections | Select-Object -First $MaxDetections)
$userIds = @($follow | ForEach-Object UserId | Where-Object { $_ } | Sort-Object -Unique)

# Step 3: GET /auditLogs/signIns?$filter=correlationId eq '{correlationId}'
$null = Invoke-ReadStep '3-detection-sign-ins' {
    foreach ($d in $follow | Where-Object CorrelationId) {
        Get-MgAuditLogSignIn -Filter "correlationId eq '$($d.CorrelationId)'" -Top 5 |
            Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName, IPAddress, ClientAppUsed, ConditionalAccessStatus,
                @{n = 'ErrorCode'; e = { $_.Status.ErrorCode } }, @{n = 'Device'; e = { $_.DeviceDetail.OperatingSystem } }, CorrelationId
    }
}

# Step 4: GET /users/{id}/authentication/methods
$null = Invoke-ReadStep '4-auth-methods' {
    foreach ($id in $userIds) {
        Get-MgUserAuthenticationMethod -UserId $id | Select-Object @{n = 'UserId'; e = { $id } }, Id, @{n = 'Method'; e = { Get-Field $_ '@odata.type' } },
            @{n = 'CreatedDateTime'; e = { Get-Field $_ 'createdDateTime' } }
    }
}

# Step 5: GET /auditLogs/directoryAudits (changes the users made, such as new MFA methods)
$null = Invoke-ReadStep '5-changes-by-users' {
    foreach ($id in $userIds) {
        Get-MgAuditLogDirectoryAudit -Filter "initiatedBy/user/id eq '$id' and activityDateTime ge $since" -All |
            Select-Object @{n = 'UserId'; e = { $id } }, ActivityDateTime, ActivityDisplayName, Category, Result
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
