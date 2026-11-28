#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Audit and hunt AI usage (read-only example).

.DESCRIPTION
Purpose: Security teams need to see who uses AI, on what data, and spot misuse such as prompt-based exfiltration.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-audit-hunt-ai-usage

Scopes (delegated, read-only): AuditLogsQuery.Read.All, ThreatHunting.Read.All, User.ReadBasic.All, SecurityAlert.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Audit Reader or Audit Logs (Purview) for the audit search; Security Reader for hunting and alerts. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Purview Audit (Standard). Defender XDR (with Defender for Cloud Apps) for CloudAppEvents.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): auditLog/queries (step 1) and runHuntingQuery (step 2)..
- It reads audit records with AuditLogsQuery.Read.All: Learn lists narrower workload permissions (such as AuditLogsQuery-Entra.Read.All) but doesn't say which one covers CopilotInteraction records.
- The audit search can take many minutes; the script waits up to -WaitMinutes.
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

.PARAMETER WaitMinutes
How long to wait for the audit search. Default 30.

.PARAMETER MaxRecords
Upper limit on audit records read. Default 1000.

.PARAMETER TopUsers
Most active users looked up in step 3. Default 10.

.EXAMPLE
./audit-hunt-ai-usage.ps1 -Days 7

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-audit-hunt-ai-usage
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7,
    [int]$WaitMinutes = 30,
    [int]$MaxRecords = 1000,
    [int]$TopUsers = 10
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('AuditLogsQuery.Read.All', 'ThreatHunting.Read.All', 'User.ReadBasic.All', 'SecurityAlert.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('audit-hunt-ai-usage-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

function Get-AuditRecord {
    # Creates an audit log search (read-only, uses POST), waits for it, then reads the records with GET.
    param([Parameter(Mandatory)][hashtable]$Body, [int]$WaitMinutes = 30, [int]$MaxRecords = 1000)
    $query = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/security/auditLog/queries" -Body $Body -OutputType PSObject  # read-only, uses POST
    $id = Get-Field $query 'id'
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    do {
        Start-Sleep -Seconds 30
        $status = Get-Field (Invoke-MgGraphRequest -Method GET -Uri "$graph/v1.0/security/auditLog/queries/$id" -OutputType PSObject) 'status'
        Write-Information "Audit search $id is $status" -InformationAction Continue
    } while ($status -in @('notStarted', 'running') -and (Get-Date) -lt $deadline)
    if ($status -ne 'succeeded') { throw "Audit search $id ended as '$status' (or did not finish within $WaitMinutes minutes). Read it later with GET /security/auditLog/queries/$id/records." }
    Get-GraphCollection -Uri "$graph/v1.0/security/auditLog/queries/$id/records" -MaxItems $MaxRecords |
        Select-Object @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }, @{n = 'userPrincipalName'; e = { Get-Field $_ 'userPrincipalName' } },
            @{n = 'operation'; e = { Get-Field $_ 'operation' } }, @{n = 'auditLogRecordType'; e = { Get-Field $_ 'auditLogRecordType' } },
            @{n = 'service'; e = { Get-Field $_ 'service' } }, @{n = 'objectId'; e = { Get-Field $_ 'objectId' } }, @{n = 'clientIp'; e = { Get-Field $_ 'clientIp' } }
}

function Invoke-HuntingQuery {
    # Advanced hunting (read-only, uses POST). Returns the result rows.
    param([Parameter(Mandatory)][string]$Query, [string]$Timespan = 'P30D')
    $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/security/runHuntingQuery" -Body @{ Query = $Query; Timespan = $Timespan } -OutputType PSObject  # read-only, uses POST
    @(Get-Field $r 'results')
}

# Step 1: POST /security/auditLog/queries (recordTypeFilters: CopilotInteraction) (read-only, uses POST), then GET its records
$null = Invoke-ReadStep '1-copilot-audit-records' {
    Get-AuditRecord -WaitMinutes $WaitMinutes -MaxRecords $MaxRecords -Body @{
        displayName = "MGC Copilot interactions $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        filterStartDateTime = Get-UtcStamp -DaysAgo $Days; filterEndDateTime = Get-UtcStamp
        recordTypeFilters = @('CopilotInteraction')
    }
}

# Step 2: POST /security/runHuntingQuery (CloudAppEvents) (read-only, uses POST)
$hunt = @(Invoke-ReadStep '2-hunting-copilot-events' {
    Invoke-HuntingQuery -Timespan "P$($Days)D" -Query "CloudAppEvents | where ActionType == 'CopilotInteraction' | summarize Interactions = count() by AccountObjectId, AccountDisplayName, Application | top 200 by Interactions" |
        Select-Object AccountObjectId, AccountDisplayName, Application, Interactions
})

# Step 3: GET /users/{id} (the most active users)
$null = Invoke-ReadStep '3-top-users' {
    foreach ($id in $hunt | Sort-Object Interactions -Descending | Select-Object -ExpandProperty AccountObjectId -Unique -First $TopUsers) {
        try { Get-MgUser -UserId $id -Property id,displayName,userPrincipalName,department,jobTitle | Select-Object Id, DisplayName, UserPrincipalName, Department, JobTitle }
        catch { Write-Verbose "Not readable: $id" }
    }
}

# Step 4: GET /security/alerts_v2
$null = Invoke-ReadStep '4-alerts' {
    Get-MgSecurityAlertV2 -Filter "createdDateTime ge $(Get-UtcStamp -DaysAgo $Days)" -All | Select-Object Id, Title, Severity, Status, ServiceSource, Category, CreatedDateTime
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
