#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Sites
<#
.SYNOPSIS
"Anyone" and organisation-wide sharing link audit (read-only example).

.DESCRIPTION
Purpose: Anyone links work for whoever holds them and organisation-wide links reach every employee, so both are easy oversharing.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-sharing-link-audit

Scopes (delegated, read-only): SharePointTenantSettings.Read.All, Sites.Read.All, Files.Read.All, AuditLogsQuery.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): Sites.Read.All (step 2 without -SiteId), Sites.FullControl.All (Learn: needed to process permissions through delta in step 3)
Entra roles: SharePoint Administrator or Global Reader for tenant settings; Audit Reader (Purview) for the audit search. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: None stated for the Graph calls; Purview Audit for the audit search.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): auditLog/queries (step 5)..
- It does not remove links or change sharing settings.
- It does not export sharing link URLs.
- It reads audit records with AuditLogsQuery.Read.All; Learn lists narrower workload permissions.
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

.PARAMETER MaxItemsPerDrive
Upper limit on items read per library in step 3. Default 5000.

.PARAMETER Days
How far back to search the audit log. Default 30.

.PARAMETER WaitMinutes
How long to wait for the audit search. Default 30.

.PARAMETER MaxRecords
Upper limit on audit records read. Default 1000.

.EXAMPLE
./sharing-link-audit.ps1 -SiteId contoso.sharepoint.com:/sites/Finance

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Sites -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-sharing-link-audit
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [string[]]$SiteId,
    [int]$MaxItemsPerDrive = 5000,
    [int]$Days = 30,
    [int]$WaitMinutes = 30,
    [int]$MaxRecords = 1000
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('SharePointTenantSettings.Read.All', 'Sites.Read.All', 'Files.Read.All', 'AuditLogsQuery.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('sharing-link-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /admin/sharepoint/settings
$null = Invoke-ReadStep '1-tenant-sharing' {
    Get-MgAdminSharepointSetting | Select-Object SharingCapability, SharingDomainRestrictionMode,
        @{n = 'AllowedDomains'; e = { ($_.SharingAllowedDomainList) -join ';' } }, @{n = 'BlockedDomains'; e = { ($_.SharingBlockedDomainList) -join ';' } }
}

# Step 2: GET /sites/getAllSites (or the sites named with -SiteId)
$sites = @(Invoke-ReadStep '2-sites' { Get-TargetSite -SiteId $SiteId | Select-Object @{n = 'Id'; e = { Get-Field $_ 'id' } }, @{n = 'Name'; e = { Get-Field $_ 'displayName' } }, @{n = 'WebUrl'; e = { Get-Field $_ 'webUrl' } } })

# Step 3: GET /drives/{id}/root/delta with Prefer: deltashowremovedasdeleted, deltatraversepermissiongaps, deltashowsharingchanges
$prefer = @{ Prefer = 'deltashowremovedasdeleted, deltatraversepermissiongaps, deltashowsharingchanges' }
$flagged = @(Invoke-ReadStep '3-shared-items' {
    foreach ($s in $sites) {
        foreach ($d in Get-MgSiteDrive -SiteId $s.Id -All) {
            Get-GraphCollection -Uri "$graph/v1.0/drives/$($d.Id)/root/delta" -Headers $prefer -MaxItems $MaxItemsPerDrive |
                Where-Object { (Get-Field $_ 'shared') -or @($_.PSObject.Properties.Name -match 'sharedChanged').Count } |
                Select-Object @{n = 'Site'; e = { $s.Name } }, @{n = 'DriveId'; e = { $d.Id } }, @{n = 'ItemId'; e = { Get-Field $_ 'id' } },
                    @{n = 'Name'; e = { Get-Field $_ 'name' } }, @{n = 'LastModified'; e = { Get-Field $_ 'lastModifiedDateTime' } }
        }
    }
})

# Step 4: GET /drives/{id}/items/{id}/permissions (keep anyone and organisation-wide links)
$null = Invoke-ReadStep '4-broad-links' {
    foreach ($i in $flagged) {
        Get-MgDriveItemPermission -DriveId $i.DriveId -DriveItemId $i.ItemId -All | Where-Object { $_.Link.Scope -in @('anonymous', 'organization') } |
            Select-Object @{n = 'Site'; e = { $i.Site } }, @{n = 'Item'; e = { $i.Name } }, @{n = 'LinkScope'; e = { $_.Link.Scope } }, @{n = 'LinkType'; e = { $_.Link.Type } },
                @{n = 'Roles'; e = { ($_.Roles) -join ';' } }, ExpirationDateTime, HasPassword
    }
}

# Step 5: POST /security/auditLog/queries (read-only, uses POST), filtered by operation name
$null = Invoke-ReadStep '5-link-audit-records' {
    Get-AuditRecord -WaitMinutes $WaitMinutes -MaxRecords $MaxRecords -Body @{
        displayName = "MGC sharing links $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        filterStartDateTime = Get-UtcStamp -DaysAgo $Days; filterEndDateTime = Get-UtcStamp
        operationFilters = @('AnonymousLinkCreated', 'AnonymousLinkUsed', 'CompanyLinkCreated')
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
