#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Mail, Microsoft.Graph.Security
<#
.SYNOPSIS
DLP incident triage (read-only example).

.DESCRIPTION
Purpose: A DLP alert is only the start; triage needs the matching activity, the content, its label and what was detected.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-dlp-incident-triage

Scopes (delegated, read-only): SecurityAlert.Read.All, AuditLogsQuery.Read.All, Files.Read.All, Mail.ReadBasic, ExchangeMessageTrace.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Security Reader for alerts; Audit Reader (Purview) for the audit search. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: DLP alert investigation: Microsoft 365 or Office 365 E5/A5, E5 Compliance, or E5 Information Protection and Governance. Audit (Standard) covers 180 days.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): auditLog/queries (step 2) and extractSensitivityLabels (step 7)..
- It reads audit records with AuditLogsQuery.Read.All, which covers SharePoint, Exchange and endpoint records; Learn lists narrower workload permissions.
- Steps 4, 5 and 7 run only with -DriveId/-ItemId or -MessageId; step 6 only with -SenderAddress (message trace covers at most 10 days per query).
- Step 8 reads the beta sensitive types list, which Learn doesn't document; it may fail.
- It does not resolve or close alerts.
- With delegated access Graph returns another user's mailbox data only if you can open that mailbox; otherwise run it app-only (application permission Mail.ReadBasic.All) with -UseExistingConnection.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
How far back to look. Default 7 (message trace uses at most 10).

.PARAMETER WaitMinutes
How long to wait for the audit search. Default 30.

.PARAMETER MaxRecords
Upper limit on audit records read. Default 1000.

.PARAMETER DriveId
With -ItemId: the file in an alert (steps 4 and 7).

.PARAMETER ItemId
See -DriveId.

.PARAMETER UserPrincipalName
With -MessageId: the mailbox holding the message (step 5).

.PARAMETER MessageId
See -UserPrincipalName.

.PARAMETER SenderAddress
Sender to trace (step 6).

.EXAMPLE
./dlp-incident-triage.ps1 -Days 7 -SenderAddress someone@contoso.com

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Mail, Microsoft.Graph.Security -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-dlp-incident-triage
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7,
    [int]$WaitMinutes = 30,
    [int]$MaxRecords = 1000,
    [string]$DriveId,
    [string]$ItemId,
    [string]$UserPrincipalName,
    [string]$MessageId,
    [string]$SenderAddress
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('SecurityAlert.Read.All', 'AuditLogsQuery.Read.All', 'Files.Read.All', 'Mail.ReadBasic', 'ExchangeMessageTrace.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('dlp-incident-triage-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /security/alerts_v2?$filter=serviceSource eq 'dataLossPrevention'
$null = Invoke-ReadStep '1-dlp-alerts' {
    Get-MgSecurityAlertV2 -Filter "serviceSource eq 'dataLossPrevention' and createdDateTime ge $(Get-UtcStamp -DaysAgo $Days)" -All |
        Select-Object Id, Title, Severity, Status, CreatedDateTime, IncidentId, AlertWebUrl
}

# Steps 2 and 3: POST /security/auditLog/queries (read-only, uses POST), then GET /security/auditLog/queries/{id}/records
$null = Invoke-ReadStep '3-dlp-audit-records' {
    Get-AuditRecord -WaitMinutes $WaitMinutes -MaxRecords $MaxRecords -Body @{
        displayName = "MGC DLP matches $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        filterStartDateTime = Get-UtcStamp -DaysAgo $Days; filterEndDateTime = Get-UtcStamp
        recordTypeFilters = @('ComplianceDLPSharePoint', 'ComplianceDLPExchange', 'DLPEndpoint')
    }
}

# Step 4: GET /drives/{id}/items/{id}
if ($DriveId -and $ItemId) {
    $null = Invoke-ReadStep '4-file' { Get-MgDriveItem -DriveId $DriveId -DriveItemId $ItemId | Select-Object Id, Name, WebUrl, Size, LastModifiedDateTime, @{n = 'ModifiedBy'; e = { $_.LastModifiedBy.User.DisplayName } } }
} else { Write-Skip 'Steps 4 and 7 need -DriveId and -ItemId.' }

# Step 5: GET /users/{id}/messages/{id}
if ($UserPrincipalName -and $MessageId) {
    $null = Invoke-ReadStep '5-message' { Get-MgUserMessage -UserId $UserPrincipalName -MessageId $MessageId -Property id,subject,receivedDateTime,from,hasAttachments | Select-Object Id, Subject, ReceivedDateTime, @{n = 'From'; e = { $_.From.EmailAddress.Address } }, HasAttachments }
} else { Write-Skip 'Step 5 needs -UserPrincipalName and -MessageId.' }

# Step 6: GET /admin/exchange/tracing/messageTraces (both receivedDateTime bounds, at most 10 days)
if ($SenderAddress) {
    $null = Invoke-ReadStep '6-message-trace' {
        $filter = "receivedDateTime ge $(Get-UtcStamp -DaysAgo ([math]::Min($Days, 10))) and receivedDateTime le $(Get-UtcStamp) and senderAddress eq '$SenderAddress'"
        Get-GraphCollection -Uri "$graph/v1.0/admin/exchange/tracing/messageTraces?`$filter=$([uri]::EscapeDataString($filter))" |
            Select-Object @{n = 'receivedDateTime'; e = { Get-Field $_ 'receivedDateTime' } }, @{n = 'senderAddress'; e = { Get-Field $_ 'senderAddress' } },
                @{n = 'recipientAddress'; e = { Get-Field $_ 'recipientAddress' } }, @{n = 'subject'; e = { Get-Field $_ 'subject' } }, @{n = 'status'; e = { Get-Field $_ 'status' } }
    }
} else { Write-Skip 'Step 6 needs -SenderAddress.' }

# Step 7: POST /drives/{id}/items/{id}/extractSensitivityLabels (read-only, uses POST)
if ($DriveId -and $ItemId) {
    $null = Invoke-ReadStep '7-file-labels' {
        $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/drives/$DriveId/items/$ItemId/extractSensitivityLabels" -OutputType PSObject  # read-only, uses POST
        foreach ($l in @(Get-Field (Get-Field $r 'value') 'labels')) {
            [pscustomobject]@{ sensitivityLabelId = Get-Field $l 'sensitivityLabelId'; assignmentMethod = Get-Field $l 'assignmentMethod' }
        }
    }
}

# Step 8: GET /beta/dataClassification/sensitiveTypes (not documented on Learn; may fail)
$null = Invoke-ReadStep '8-sensitive-types-beta' {
    Get-GraphCollection -Uri "$graph/beta/dataClassification/sensitiveTypes" |
        Select-Object @{n = 'id'; e = { Get-Field $_ 'id' } }, @{n = 'name'; e = { Get-Field $_ 'name' } }, @{n = 'publisherName'; e = { Get-Field $_ 'publisherName' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
