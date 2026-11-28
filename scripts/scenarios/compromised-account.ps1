#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Mail, Microsoft.Graph.Reports, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Compromised account investigation (read-only example).

.DESCRIPTION
Purpose: Business email compromise moves fast; you need the alert, the sign-ins, the persistence (rules) and the containment in one sweep.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-compromised-account

Scopes (delegated, read-only): User.Read.All, SecurityIncident.Read.All, SecurityAlert.Read.All, IdentityRiskyUser.Read.All, AuditLog.Read.All, MailboxSettings.Read, ThreatHunting.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): MailboxSettings.Read (step 6, for another user's inbox rules)
Entra roles: Security Reader covers incidents, alerts, risky users and hunting; Global Reader or Reports Reader covers the logs. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Microsoft Defender XDR. Entra ID P2 for risky users. Entra ID P1 for sign-in logs.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): runHuntingQuery (step 7)..
- It does not confirm the user compromised (step 3) or revoke sessions (step 8): those steps changes data, so this script leaves it out. It reads the user's risk state instead.
- With delegated access Graph returns another user's mailbox data only if you can open that mailbox; otherwise run it app-only (application permission MailboxSettings.Read) with -UseExistingConnection.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER UserPrincipalName
The user to look at, for example someone@contoso.com.

.PARAMETER Days
How far back to look. Default 7.

.EXAMPLE
./compromised-account.ps1 -UserPrincipalName someone@contoso.com -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Mail, Microsoft.Graph.Reports, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-compromised-account
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [int]$Days = 7
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.Read.All', 'SecurityIncident.Read.All', 'SecurityAlert.Read.All', 'IdentityRiskyUser.Read.All', 'AuditLog.Read.All', 'MailboxSettings.Read', 'ThreatHunting.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('compromised-account-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

function Invoke-HuntingQuery {
    # Advanced hunting (read-only, uses POST). Returns the result rows.
    param([Parameter(Mandatory)][string]$Query, [string]$Timespan = 'P30D')
    $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/security/runHuntingQuery" -Body @{ Query = $Query; Timespan = $Timespan } -OutputType PSObject  # read-only, uses POST
    @(Get-Field $r 'results')
}

$user = Get-MgUser -UserId $UserPrincipalName -Property id,displayName,userPrincipalName
$userId = $user.Id
$since = Get-UtcStamp -DaysAgo $Days
$upnRx = [regex]::Escape($user.UserPrincipalName)

# Step 1: GET /security/incidents?$expand=alerts (incidents whose alerts name this user)
$null = Invoke-ReadStep '1-incidents' {
    Get-MgSecurityIncident -Filter "createdDateTime ge $since" -ExpandProperty alerts -All |
        Where-Object { ($_.Alerts | ConvertTo-Json -Depth 8 -Compress) -match $upnRx } |
        Select-Object Id, DisplayName, Severity, Status, CreatedDateTime, @{n = 'Alerts'; e = { @($_.Alerts).Count } }, IncidentWebUrl
}

# Step 2: GET /security/alerts_v2 (alerts whose evidence names this user)
$null = Invoke-ReadStep '2-alerts' {
    Get-MgSecurityAlertV2 -Filter "createdDateTime ge $since" -All |
        Where-Object { ($_.Evidence | ConvertTo-Json -Depth 8 -Compress) -match $upnRx } |
        Select-Object Id, Title, Severity, Status, ServiceSource, Category, CreatedDateTime, IncidentId
}

# Step 3: confirming the user compromised changes data. This reads the user's risk state instead (GET /identityProtection/riskyUsers).
$null = Invoke-ReadStep '3-risk-state' {
    Get-MgRiskyUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" | Select-Object Id, UserPrincipalName, RiskLevel, RiskState, RiskDetail, RiskLastUpdatedDateTime
}

# Step 4: GET /auditLogs/signIns
$null = Invoke-ReadStep '4-sign-ins' {
    Get-MgAuditLogSignIn -Filter "userId eq '$userId' and createdDateTime ge $since" -All |
        Select-Object CreatedDateTime, AppDisplayName, IPAddress, ClientAppUsed, ConditionalAccessStatus, RiskLevelDuringSignIn,
            @{n = 'ErrorCode'; e = { $_.Status.ErrorCode } }, @{n = 'Country'; e = { $_.Location.CountryOrRegion } }, CorrelationId
}

# Step 5: GET /auditLogs/directoryAudits?$filter=initiatedBy/user/id eq '{id}'
$null = Invoke-ReadStep '5-changes-by-user' {
    Get-MgAuditLogDirectoryAudit -Filter "initiatedBy/user/id eq '$userId' and activityDateTime ge $since" -All |
        Select-Object ActivityDateTime, ActivityDisplayName, Category, Result, @{n = 'Targets'; e = { ($_.TargetResources.DisplayName | Where-Object { $_ }) -join ';' } }
}

# Step 6: GET /users/{id}/mailFolders/inbox/messageRules
$null = Invoke-ReadStep '6-inbox-rules' {
    Get-MgUserMailFolderMessageRule -UserId $userId -MailFolderId 'inbox' -All |
        Select-Object DisplayName, IsEnabled, Sequence,
            @{n = 'ForwardTo'; e = { ($_.Actions.ForwardTo.EmailAddress.Address) -join ';' } },
            @{n = 'RedirectTo'; e = { ($_.Actions.RedirectTo.EmailAddress.Address) -join ';' } },
            @{n = 'DeletesMessage'; e = { $_.Actions.Delete } }, @{n = 'MovesToFolder'; e = { $_.Actions.MoveToFolder } }
}

# Step 7: POST /security/runHuntingQuery (read-only, uses POST)
$null = Invoke-ReadStep '7-hunting-cloud-app-events' {
    Invoke-HuntingQuery -Timespan "P$($Days)D" -Query "CloudAppEvents | where AccountObjectId == '$userId' | summarize Events = count() by ActionType, Application, CountryCode | top 200 by Events" |
        Select-Object ActionType, Application, CountryCode, Events
}

# Step 8: revoking sessions changes data, so it is not in this script.

Write-Information "Done. Results: $runFolder" -InformationAction Continue
