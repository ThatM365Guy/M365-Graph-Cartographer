#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Phishing simulation follow-up (read-only example).

.DESCRIPTION
Purpose: People who fall for simulated phishing again and again are the likeliest real victims, so check their sign-in protection and risk.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-phishing-simulation-followup

Scopes (delegated, read-only): AttackSimulation.Read.All, User.Read.All, AuditLog.Read.All, IdentityRiskyUser.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Attack Simulation Administrator or Security Reader for simulations; Reports Reader for registration details. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Microsoft 365 E5 or Microsoft Defender for Office 365 Plan 2.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not assign training or change anyone's account.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER MaxUsers
Repeat offenders followed up in steps 3 to 5. Default 50.

.EXAMPLE
./phishing-simulation-followup.ps1

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-phishing-simulation-followup
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$MaxUsers = 50
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('AttackSimulation.Read.All', 'User.Read.All', 'AuditLog.Read.All', 'IdentityRiskyUser.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('phishing-simulation-followup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /security/attackSimulation/simulations
$null = Invoke-ReadStep '1-simulations' {
    Get-MgSecurityAttackSimulation -All | Select-Object Id, DisplayName, Status, AttackTechnique, AttackType, LaunchDateTime, CompletionDateTime
}

# Step 2: GET /reports/security/getAttackSimulationRepeatOffenders
$offenders = @(Invoke-ReadStep '2-repeat-offenders' {
    Get-GraphCollection -Uri "$graph/v1.0/reports/security/getAttackSimulationRepeatOffenders" | ForEach-Object {
        $u = Get-Field $_ 'attackSimulationUser'
        [pscustomobject]@{ UserId = Get-Field $u 'userId'; DisplayName = Get-Field $u 'displayName'; Email = Get-Field $u 'email'; RepeatOffenceCount = Get-Field $_ 'repeatOffenceCount' }
    } | Sort-Object RepeatOffenceCount -Descending
})
$follow = @($offenders | Where-Object UserId | Select-Object -First $MaxUsers)

# Step 3: GET /users/{id}
$users = @(Invoke-ReadStep '3-users' {
    foreach ($o in $follow) {
        try { Get-MgUser -UserId $o.UserId -Property id,displayName,userPrincipalName,department,jobTitle,accountEnabled | Select-Object Id, DisplayName, UserPrincipalName, Department, JobTitle, AccountEnabled }
        catch { Write-Verbose "Not readable: $($o.UserId)" }
    }
})

# Step 4: GET /reports/authenticationMethods/userRegistrationDetails (is each user protected by strong MFA?)
$null = Invoke-ReadStep '4-registration-details' {
    foreach ($u in $users) {
        Get-MgReportAuthenticationMethodUserRegistrationDetail -Filter "userPrincipalName eq '$($u.UserPrincipalName)'" |
            Select-Object UserPrincipalName, IsMfaRegistered, IsPasswordlessCapable, IsSsprRegistered, @{n = 'Methods'; e = { ($_.MethodsRegistered) -join ';' } }
    }
}

# Step 5: GET /identityProtection/riskyUsers
$ids = @($follow | ForEach-Object UserId)
$null = Invoke-ReadStep '5-risk-state' {
    Get-MgRiskyUser -All | Where-Object { $ids -contains $_.Id } | Select-Object Id, UserPrincipalName, RiskLevel, RiskState, RiskLastUpdatedDateTime
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
