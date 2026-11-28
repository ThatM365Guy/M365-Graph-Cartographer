#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
EWS to Graph migration of mail-integrated apps (read-only example).

.DESCRIPTION
Purpose: EWS in Exchange Online began phased disablement on 1 October 2026 and is fully retired on 1 April 2027, so apps still on it have to move to Graph.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-ews-migration

Scopes (delegated, read-only): Application.Read.All, Directory.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or Cloud Application Administrator. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: None stated.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not read the EWS usage report: that is in the Microsoft 365 admin center (Reports > Usage > Exchange > EWS usage), not Graph (step 1).
- It does not remove permissions or contact owners.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.EXAMPLE
./ews-migration.ps1

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-ews-migration
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Application.Read.All', 'Directory.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('ews-migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$exoAppId = '00000002-0000-0ff1-ce00-000000000000'

# Step 1: outside Graph
Write-Skip 'Step 1: the EWS usage report is in the Microsoft 365 admin center (Reports > Usage > Exchange > EWS usage). EWS in Exchange Online is fully retired on 1 April 2027.'

# Step 2: GET /servicePrincipals(appId='00000002-0000-0ff1-ce00-000000000000')
$exo = $null
try { $exo = Get-MgServicePrincipal -Filter "appId eq '$exoAppId'" -Property id,appId,displayName,appRoles }
catch { Write-Warning "Office 365 Exchange Online service principal: $($_.Exception.Message) (the steps that need it will warn too)" }
$roleName = @{}; foreach ($r in @($exo.AppRoles)) { $roleName["$($r.Id)"] = $r.Value }
$null = Invoke-ReadStep '2-exchange-service-principal' { $exo | Select-Object Id, AppId, DisplayName }

$spAppId = @{}
foreach ($s in Get-MgServicePrincipal -All -Property id,appId) { $spAppId[$s.Id] = $s.AppId }

# Step 3: GET /servicePrincipals(appId='00000002-...')/appRoleAssignedTo (apps with full_access_as_app)
$full = @(Invoke-ReadStep '3-full-access-as-app' {
    Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -All | Where-Object { $roleName["$($_.AppRoleId)"] -eq 'full_access_as_app' } |
        Select-Object @{n = 'App'; e = { $_.PrincipalDisplayName } }, PrincipalId, @{n = 'AppId'; e = { $spAppId[$_.PrincipalId] } }, @{n = 'Permission'; e = { $roleName["$($_.AppRoleId)"] } }, CreatedDateTime
})

# Step 4: GET /oauth2PermissionGrants?$filter=resourceId eq '{exchangeServicePrincipalObjectId}' (delegated EWS.AccessAsUser.All)
$delegated = @(Invoke-ReadStep '4-ews-delegated-grants' {
    Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($exo.Id)'" -All | Where-Object { " $($_.Scope) " -match ' EWS\.AccessAsUser\.All ' } |
        Select-Object ClientId, @{n = 'AppId'; e = { $spAppId[$_.ClientId] } }, ConsentType, PrincipalId, Scope
})

# Step 5: GET /applications(appId='{appId}')/owners (apps registered in this tenant)
$null = Invoke-ReadStep '5-owners' {
    foreach ($a in @($full.AppId) + @($delegated.AppId) | Where-Object { $_ } | Sort-Object -Unique) {
        $app = Get-MgApplication -Filter "appId eq '$a'" -Property id,appId,displayName
        if (-not $app) { [pscustomobject]@{ AppId = $a; App = '(not registered in this tenant)'; Owner = ''; OwnerUpn = '' }; continue }
        $owners = @(Get-MgApplicationOwner -ApplicationId $app.Id -All)
        if (-not $owners.Count) { [pscustomobject]@{ AppId = $a; App = $app.DisplayName; Owner = '(no owner)'; OwnerUpn = '' } }
        foreach ($o in $owners) { [pscustomobject]@{ AppId = $a; App = $app.DisplayName; Owner = Get-Field $o 'displayName'; OwnerUpn = Get-Field $o 'userPrincipalName' } }
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
