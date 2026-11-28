#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Groups, Microsoft.Graph.Security, Microsoft.Graph.Sites
<#
.SYNOPSIS
Sensitivity label coverage as a Copilot readiness gate (read-only example).

.DESCRIPTION
Purpose: Copilot respects sensitivity labels, so unlabelled sensitive content is the gap to close before a wide roll-out.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-label-copilot-readiness

Scopes (delegated, read-only): SensitivityLabel.Read, Group.Read.All, Sites.Read.All, Files.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): Sites.Read.All (step 3 without -SiteId)
Entra roles: Groups Administrator or Global Reader for group labels. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P1 for group labels; Purview licensing for the labels themselves.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): extractSensitivityLabels (step 4). Learn notes it can refresh the label metadata stored for a file; it doesn't change the file or its label..
- It does not apply or change labels.
- It doesn't give labelled-versus-unlabelled totals for the tenant: those are in Purview content explorer or the SharePoint Advanced Management sensitivity label report (step 5, outside Graph).
- Step 4 reads at most -MaxFilesPerSite top-level files per site; double key encrypted files return 423 Locked and are listed as locked.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER SiteId
One or more sites, as a site ID or hostname:/sites/path (for example contoso.sharepoint.com:/sites/Finance). Without it the script reads every site, which only works in an app-only session.

.PARAMETER MaxFilesPerSite
Top-level files read per site in step 4. Default 100.

.EXAMPLE
./label-copilot-readiness.ps1 -SiteId contoso.sharepoint.com:/sites/Finance

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Groups, Microsoft.Graph.Security, Microsoft.Graph.Sites -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-label-copilot-readiness
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [string[]]$SiteId,
    [int]$MaxFilesPerSite = 100
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('SensitivityLabel.Read', 'Group.Read.All', 'Sites.Read.All', 'Files.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('label-copilot-readiness-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

function Get-TargetSite {
    param([string[]]$SiteId)
    if ($SiteId) {
        foreach ($s in $SiteId) { Get-MgSite -SiteId $s }
    } elseif ($appOnly) {
        Get-GraphCollection -Uri "$graph/v1.0/sites/getAllSites"
    } else {
        Write-Skip 'GET /sites/getAllSites is application-only (Sites.Read.All). Pass -SiteId, or connect app-only and add -UseExistingConnection.'
    }
}

# Step 1: GET /security/dataSecurityAndGovernance/sensitivityLabels
$labels = @(Invoke-ReadStep '1-labels' {
    Get-MgSecurityDataSecurityAndGovernanceSensitivityLabel -All | Select-Object Id, Name, DisplayName, Priority, HasProtection, IsScopedToUser
})
$labelName = @{}; foreach ($l in $labels) { $labelName["$($l.Id)"] = if ($l.DisplayName) { $l.DisplayName } else { $l.Name } }

# Step 2: GET /groups/{id}?$select=assignedLabels (Microsoft 365 groups and their team sites)
$null = Invoke-ReadStep '2-group-container-labels' {
    Get-MgGroup -Filter "groupTypes/any(c:c eq 'Unified')" -All -Property id,displayName,assignedLabels |
        Select-Object Id, DisplayName, @{n = 'Label'; e = { ($_.AssignedLabels.DisplayName) -join ';' } }, @{n = 'Labelled'; e = { [bool]@($_.AssignedLabels).Count } }
}

# Step 3: GET /sites/getAllSites (or the sites named with -SiteId)
$sites = @(Invoke-ReadStep '3-sites' { Get-TargetSite -SiteId $SiteId | Select-Object @{n = 'Id'; e = { Get-Field $_ 'id' } }, @{n = 'Name'; e = { Get-Field $_ 'displayName' } }, @{n = 'WebUrl'; e = { Get-Field $_ 'webUrl' } } })

# Step 4: POST /drives/{id}/items/{id}/extractSensitivityLabels (read-only, uses POST)
$null = Invoke-ReadStep '4-file-labels' {
    foreach ($s in $sites) {
        try { $drive = Get-MgSiteDefaultDrive -SiteId $s.Id } catch { Write-Verbose "$($s.WebUrl): no default library"; continue }
        foreach ($item in Get-MgDriveItemChild -DriveId $drive.Id -DriveItemId 'root' -Top $MaxFilesPerSite | Where-Object { $_.File }) {
            try {
                $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/drives/$($drive.Id)/items/$($item.Id)/extractSensitivityLabels" -OutputType PSObject  # read-only, uses POST
                $found = @(Get-Field (Get-Field $r 'value') 'labels')
                [pscustomobject]@{ Site = $s.Name; File = $item.Name; Labels = (($found | ForEach-Object { $labelName["$(Get-Field $_ 'sensitivityLabelId')"] }) -join ';'); State = if ($found.Count) { 'labelled' } else { 'no label' } }
            } catch {
                $state = if ("$($_.Exception.Message)" -match '423|Locked') { 'locked' } else { 'error' }
                [pscustomobject]@{ Site = $s.Name; File = $item.Name; Labels = ''; State = $state }
            }
        }
    }
}

# Step 5: outside Graph
Write-Skip 'Step 5: labelled-versus-unlabelled totals are in Purview content explorer or the SharePoint Advanced Management sensitivity label report, not Graph.'

Write-Information "Done. Results: $runFolder" -InformationAction Continue
