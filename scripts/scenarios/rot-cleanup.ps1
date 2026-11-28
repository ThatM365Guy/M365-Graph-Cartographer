#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Reports, Microsoft.Graph.Sites
<#
.SYNOPSIS
ROT clean-up: stale, duplicate and orphaned content (read-only example).

.DESCRIPTION
Purpose: Redundant, obsolete and trivial content costs storage, slows search and feeds Copilot stale answers; clear it without breaking retention.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-rot-cleanup

Scopes (delegated, read-only): Reports.Read.All, ReportSettings.Read.All, Sites.Read.All, Files.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Reports Reader for usage reports. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: None stated for the Graph calls.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It deletes nothing and doesn't mark anything for deletion.
- It doesn't find duplicates: Learn describes no duplicate-detection method in Graph.
- Steps 2 to 6 run only for the sites you name with -SiteId.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER SiteId
Sites to look inside (steps 2 to 6), as a site ID or hostname:/sites/path.

.PARAMETER DaysStale
Files not changed for this many days count as stale. Default 365.

.PARAMETER MaxItemsPerDrive
Upper limit on items read per library. Default 5000.

.PARAMETER MaxFilesToCheck
Largest stale files whose versions and retention labels are read. Default 50.

.EXAMPLE
./rot-cleanup.ps1 -SiteId contoso.sharepoint.com:/sites/Archive -DaysStale 730

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Reports, Microsoft.Graph.Sites -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-rot-cleanup
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [string[]]$SiteId,
    [int]$DaysStale = 365,
    [int]$MaxItemsPerDrive = 5000,
    [int]$MaxFilesToCheck = 50
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Reports.Read.All', 'ReportSettings.Read.All', 'Sites.Read.All', 'Files.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('rot-cleanup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /reports/getSharePointSiteUsageDetail(period='D180') (CSV straight from Microsoft)
try {
    if ((Get-MgAdminReportSetting).DisplayConcealedNames) { Write-Warning 'Report names are concealed (GET /admin/reportSettings): site and owner names in the usage report are hashed.' }
} catch { Write-Verbose "Report settings: $($_.Exception.Message)" }
try {
    Get-MgReportSharePointSiteUsageDetail -Period 'D180' -OutFile (Join-Path $runFolder '1-sharepoint-site-usage-detail.csv')
    Write-Information '1-sharepoint-site-usage-detail.csv written' -InformationAction Continue
} catch { Write-Warning "1-sharepoint-site-usage-detail: $($_.Exception.Message)" }

if (-not $SiteId) { Write-Skip 'Steps 2 to 6 need -SiteId.' } else {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$DaysStale)

    # Step 2: GET /sites/{hostname}:/sites/{path}
    $sites = @(Invoke-ReadStep '2-sites' { foreach ($s in $SiteId) { Get-MgSite -SiteId $s | Select-Object Id, DisplayName, WebUrl, LastModifiedDateTime } })

    # Step 3: GET /sites/{id}/drives (quota and owner)
    $drives = @(Invoke-ReadStep '3-drives' {
        foreach ($s in $sites) {
            Get-MgSiteDrive -SiteId $s.Id -All | Select-Object @{n = 'Site'; e = { $s.DisplayName } }, Id, Name, DriveType,
                @{n = 'UsedBytes'; e = { $_.Quota.Used } }, @{n = 'TotalBytes'; e = { $_.Quota.Total } }, @{n = 'Owner'; e = { $_.Owner.User.DisplayName } }
        }
    })

    # Step 4: GET /drives/{id}/root/delta (delta has no $filter, so old files are picked out here)
    $stale = @(Invoke-ReadStep '4-stale-files' {
        foreach ($d in $drives) {
            Get-GraphCollection -Uri "$graph/v1.0/drives/$($d.Id)/root/delta" -MaxItems $MaxItemsPerDrive |
                Where-Object { (Get-Field $_ 'file') -and -not (Get-Field $_ 'deleted') -and ([datetime](Get-Field $_ 'lastModifiedDateTime')).ToUniversalTime() -lt $cutoff } |
                Select-Object @{n = 'Site'; e = { $d.Site } }, @{n = 'DriveId'; e = { $d.Id } }, @{n = 'ItemId'; e = { Get-Field $_ 'id' } }, @{n = 'Name'; e = { Get-Field $_ 'name' } },
                    @{n = 'Size'; e = { Get-Field $_ 'size' } }, @{n = 'LastModified'; e = { Get-Field $_ 'lastModifiedDateTime' } },
                    @{n = 'Folder'; e = { Get-Field (Get-Field $_ 'parentReference') 'path' } }
        }
    })
    $largest = @($stale | Sort-Object { [long]$_.Size } -Descending | Select-Object -First $MaxFilesToCheck)

    # Step 5: GET /drives/{id}/items/{id}/versions (newest first)
    $null = Invoke-ReadStep '5-version-counts' {
        foreach ($f in $largest) {
            $v = @(Get-MgDriveItemVersion -DriveId $f.DriveId -DriveItemId $f.ItemId -All)
            [pscustomobject]@{ Site = $f.Site; Name = $f.Name; Size = $f.Size; Versions = $v.Count; VersionBytes = ($v | Measure-Object -Property Size -Sum).Sum }
        }
    }

    # Step 6: GET /drives/{id}/items/{id}/retentionLabel (check before anything is marked for deletion)
    $null = Invoke-ReadStep '6-retention-labels' {
        foreach ($f in $largest) {
            try {
                $l = Get-MgDriveItemRetentionLabel -DriveId $f.DriveId -DriveItemId $f.ItemId
                [pscustomobject]@{ Site = $f.Site; Name = $f.Name; Label = $l.Name; DeleteAllowed = $l.RetentionSettings.IsDeleteAllowed; RecordLocked = $l.RetentionSettings.IsRecordLocked }
            } catch { [pscustomobject]@{ Site = $f.Site; Name = $f.Name; Label = ''; DeleteAllowed = ''; RecordLocked = '' } }
        }
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
