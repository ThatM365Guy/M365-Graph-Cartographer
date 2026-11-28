#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Mail, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Copilot interaction export and review (read-only example).

.DESCRIPTION
Purpose: Prompts and responses are business records; you may need to export, review, retain or hold them.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-copilot-interaction-review

Scopes (delegated, read-only): User.ReadBasic.All, Files.Read.All, Mail.ReadBasic, RecordsManagement.Read.All, eDiscovery.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): AiEnterpriseInteraction.Read.All (step 2: getAllEnterpriseInteractions has no delegated permission)
Entra roles: eDiscovery Manager (a Purview role group) for cases; Records Management for labels. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Microsoft 365 Copilot. Purview (eDiscovery Premium) for review sets and holds.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not export prompt and response text unless you add -IncludeBody.
- Step 2 runs only in an app-only session; Copilot Studio agents are not included (Learn).
- Steps 3 and 4 run only when you pass -DriveId/-ItemId or -MessageId.
- With delegated access Graph returns another user's mailbox data only if you can open that mailbox; otherwise run it app-only (application permission Mail.ReadBasic.All) with -UseExistingConnection.
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
How many days of interactions to read, ending now. Default 1.

.PARAMETER IncludeBody
Also export the prompt and response text. Off by default.

.PARAMETER DriveId
With -ItemId: a file the interactions point to (step 3).

.PARAMETER ItemId
See -DriveId.

.PARAMETER MessageId
A message the interactions point to (step 4).

.EXAMPLE
./copilot-interaction-review.ps1 -UserPrincipalName someone@contoso.com -Days 1 -UseExistingConnection

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Mail, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-copilot-interaction-review
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [int]$Days = 1,
    [switch]$IncludeBody,
    [string]$DriveId,
    [string]$ItemId,
    [string]$MessageId
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.ReadBasic.All', 'Files.Read.All', 'Mail.ReadBasic', 'RecordsManagement.Read.All', 'eDiscovery.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('copilot-interaction-review-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /users/{id | userPrincipalName}
$user = Get-MgUser -UserId $UserPrincipalName -Property id,displayName,userPrincipalName,accountEnabled
$null = Invoke-ReadStep '1-user' { $user | Select-Object Id, DisplayName, UserPrincipalName, AccountEnabled }

# Step 2: GET /copilot/users/{id}/interactionHistory/getAllEnterpriseInteractions (application only; both date bounds are required)
if (-not $appOnly) { Write-Skip 'Step 2 is application-only (AiEnterpriseInteraction.Read.All). Connect app-only and add -UseExistingConnection.' } else {
    $null = Invoke-ReadStep '2-copilot-interactions' {
        $filter = "createdDateTime gt $(Get-UtcStamp -DaysAgo $Days) and createdDateTime lt $(Get-UtcStamp)"
        Get-GraphCollection -Uri "$graph/v1.0/copilot/users/$($user.Id)/interactionHistory/getAllEnterpriseInteractions?`$top=100&`$filter=$([uri]::EscapeDataString($filter))" |
            Select-Object @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }, @{n = 'appClass'; e = { Get-Field $_ 'appClass' } },
                @{n = 'interactionType'; e = { Get-Field $_ 'interactionType' } }, @{n = 'sessionId'; e = { Get-Field $_ 'sessionId' } },
                @{n = 'requestId'; e = { Get-Field $_ 'requestId' } }, @{n = 'body'; e = { if ($IncludeBody) { Get-Field (Get-Field $_ 'body') 'content' } } }
    }
}

# Step 3: GET /drives/{id}/items/{id}
if ($DriveId -and $ItemId) {
    $null = Invoke-ReadStep '3-file' { Get-MgDriveItem -DriveId $DriveId -DriveItemId $ItemId | Select-Object Id, Name, WebUrl, Size, LastModifiedDateTime, @{n = 'ModifiedBy'; e = { $_.LastModifiedBy.User.DisplayName } } }
} else { Write-Skip 'Step 3 needs -DriveId and -ItemId.' }

# Step 4: GET /users/{id}/messages/{id}
if ($MessageId) {
    $null = Invoke-ReadStep '4-message' { Get-MgUserMessage -UserId $user.Id -MessageId $MessageId -Property id,subject,receivedDateTime,from,hasAttachments | Select-Object Id, Subject, ReceivedDateTime, @{n = 'From'; e = { $_.From.EmailAddress.Address } }, HasAttachments }
} else { Write-Skip 'Step 4 needs -MessageId.' }

# Step 5: GET /security/labels/retentionLabels
$null = Invoke-ReadStep '5-retention-labels' {
    Get-MgSecurityLabelRetentionLabel -All | Select-Object Id, DisplayName, BehaviorDuringRetentionPeriod, ActionAfterRetentionPeriod, RetentionTrigger, IsInUse
}

# Step 6: GET /security/cases/ediscoveryCases
$null = Invoke-ReadStep '6-ediscovery-cases' {
    Get-MgSecurityCaseEdiscoveryCase -All | Select-Object Id, DisplayName, Status, CreatedDateTime, LastModifiedDateTime
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
