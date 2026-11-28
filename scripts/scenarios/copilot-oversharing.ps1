#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Sites
<#
.SYNOPSIS
Oversharing check before Copilot rollout (read-only example).

.DESCRIPTION
Purpose: Copilot surfaces whatever a user can already open, so overshared sites become Copilot answers.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-copilot-oversharing

Scopes (delegated, read-only): Sites.Read.All, Files.Read.All, Reports.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): Sites.Read.All (step 1 without -SiteId)
Entra roles: SharePoint Administrator or Global Reader for sites; Reports Reader or AI Administrator for the Copilot report. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Microsoft 365 Copilot. SharePoint Advanced Management for its oversharing reports.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): search/query (step 3)..
- It does not apply sensitivity labels (step 4) or change sharing: those changes data, so this script leaves it out.
- It does not export sharing link URLs.
- Step 3 runs only in a delegated session: with application permissions the search API also needs a region.
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

.PARAMETER MaxItemsPerSite
Top-level items checked per site in step 2. Default 200.

.PARAMETER SearchText
What to search for in step 3. Default confidential.

.EXAMPLE
./copilot-oversharing.ps1 -SiteId contoso.sharepoint.com:/sites/Finance -SearchText 'salary'

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Sites -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-copilot-oversharing
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [string[]]$SiteId,
    [int]$MaxItemsPerSite = 200,
    [string]$SearchText = 'confidential'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Sites.Read.All', 'Files.Read.All', 'Reports.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('copilot-oversharing-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /sites/getAllSites (or the sites named with -SiteId)
$sites = @(Invoke-ReadStep '1-sites' { Get-TargetSite -SiteId $SiteId | Select-Object @{n = 'Id'; e = { Get-Field $_ 'id' } }, @{n = 'Name'; e = { Get-Field $_ 'displayName' } }, @{n = 'WebUrl'; e = { Get-Field $_ 'webUrl' } } })

# Step 2: GET /drives/{id}/items/{id}/permissions (links and grants on each site's top-level items)
$null = Invoke-ReadStep '2-broad-permissions' {
    foreach ($s in $sites) {
        try { $drive = Get-MgSiteDefaultDrive -SiteId $s.Id } catch { Write-Verbose "$($s.WebUrl): no default library"; continue }
        foreach ($item in Get-MgDriveItemChild -DriveId $drive.Id -DriveItemId 'root' -Top $MaxItemsPerSite) {
            foreach ($p in Get-MgDriveItemPermission -DriveId $drive.Id -DriveItemId $item.Id -All) {
                if ($p.Link.Scope -in @('anonymous', 'organization') -or $p.GrantedToV2.SiteGroup.DisplayName -match 'Everyone') {
                    [pscustomobject]@{ Site = $s.Name; Item = $item.Name; LinkScope = $p.Link.Scope; LinkType = $p.Link.Type; Roles = ($p.Roles -join ';')
                        GrantedToGroup = $p.GrantedToV2.SiteGroup.DisplayName; Expires = $p.ExpirationDateTime }
                }
            }
        }
    }
}

# Step 3: POST /search/query (entityTypes: driveItem) (read-only, uses POST)
if ($appOnly) { Write-Skip 'Step 3 runs in a delegated session only (app-only search needs a region).' } else {
    $null = Invoke-ReadStep '3-search-hits' {
        $body = @{ requests = @(@{ entityTypes = @('driveItem'); query = @{ queryString = $SearchText }; from = 0; size = 200 }) }
        $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/search/query" -Body $body -OutputType PSObject  # read-only, uses POST
        foreach ($resp in @(Get-Field $r 'value')) { foreach ($c in @(Get-Field $resp 'hitsContainers')) { foreach ($h in @(Get-Field $c 'hits')) {
            $res = Get-Field $h 'resource'
            [pscustomobject]@{ Name = Get-Field $res 'name'; WebUrl = Get-Field $res 'webUrl'; LastModified = Get-Field $res 'lastModifiedDateTime'; Summary = Get-Field $h 'summary' }
        } } }
    }
}

# Step 4: applying a sensitivity label changes data, so it is not in this script.

# Step 5: GET /copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28') (CSV straight from Microsoft)
try {
    Invoke-MgGraphRequest -Method GET -Uri "$graph/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28')" -OutputFilePath (Join-Path $runFolder '5-copilot-usage-user-detail.csv')
    Write-Information '5-copilot-usage-user-detail.csv written' -InformationAction Continue
} catch { Write-Warning "5-copilot-usage-user-detail: $($_.Exception.Message)" }

Write-Information "Done. Results: $runFolder" -InformationAction Continue
