#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Event-based retention for leavers (read-only example).

.DESCRIPTION
Purpose: A leaver's records must be kept for a set time from the day they leave, not from when each file was created.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-leaver-event-retention

Scopes (delegated, read-only): User.Read.All, User-LifeCycleInfo.Read.All, RecordsManagement.Read.All, Files.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Records Management (a Purview role group) for labels and events. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Event-based retention and disposition review: Microsoft 365 or Office 365 E5/A5/G5, Purview Suite, or E5 Information Protection and Governance (Purview service description, checked 16 Nov 2026).

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not create a retention event (step 3) or set disposition review stages (step 5): those changes data, so this script leaves it out. It lists existing events and each label's stages instead.
- Step 4 runs only when you pass -DriveId and -ItemId.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER UserPrincipalName
The leaver.

.PARAMETER DriveId
With -ItemId: a file to check (step 4).

.PARAMETER ItemId
See -DriveId.

.EXAMPLE
./leaver-event-retention.ps1 -UserPrincipalName leaver@contoso.com

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-leaver-event-retention
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$DriveId,
    [string]$ItemId
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.Read.All', 'User-LifeCycleInfo.Read.All', 'RecordsManagement.Read.All', 'Files.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('leaver-event-retention-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /users/{id}?$select=employeeId,employeeLeaveDateTime
$null = Invoke-ReadStep '1-leaver' {
    Get-MgUser -UserId $UserPrincipalName -Property id,displayName,userPrincipalName,employeeId,employeeHireDate,employeeLeaveDateTime |
        Select-Object Id, DisplayName, UserPrincipalName, EmployeeId, EmployeeHireDate, EmployeeLeaveDateTime
}

# Step 2: GET /security/labels/retentionLabels (and step 5's disposition review stages, read from each label)
$null = Invoke-ReadStep '2-retention-labels' {
    Get-MgSecurityLabelRetentionLabel -All | Select-Object Id, DisplayName, RetentionTrigger, BehaviorDuringRetentionPeriod, ActionAfterRetentionPeriod,
        DefaultRecordBehavior, IsInUse, @{n = 'DispositionReviewStages'; e = { @($_.DispositionReviewStages).Count } }
}

# Step 3: creating a retention event changes data. This lists existing events and event types instead.
$null = Invoke-ReadStep '3-retention-events' {
    Get-MgSecurityTriggerRetentionEvent -All | Select-Object Id, DisplayName, EventTriggerDateTime, CreatedDateTime, @{n = 'Status'; e = { $_.EventStatus.Status } }
}
$null = Invoke-ReadStep '3-retention-event-types' {
    Get-MgSecurityTriggerTypeRetentionEventType -All | Select-Object Id, DisplayName, Description, CreatedDateTime
}

# Step 4: GET /drives/{id}/items/{id}/retentionLabel
if ($DriveId -and $ItemId) {
    $null = Invoke-ReadStep '4-file-retention-label' {
        Get-MgDriveItemRetentionLabel -DriveId $DriveId -DriveItemId $ItemId | Select-Object Name, IsLabelAppliedExplicitly, LabelAppliedDateTime,
            @{n = 'DeleteAllowed'; e = { $_.RetentionSettings.IsDeleteAllowed } }, @{n = 'RecordLocked'; e = { $_.RetentionSettings.IsRecordLocked } }
    }
} else { Write-Skip 'Step 4 needs -DriveId and -ItemId.' }

# Step 5: setting disposition review stages changes data. Step 2 shows how many stages each label has.

Write-Information "Done. Results: $runFolder" -InformationAction Continue
