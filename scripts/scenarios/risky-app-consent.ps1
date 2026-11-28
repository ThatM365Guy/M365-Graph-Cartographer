#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
Risky app consent review (read-only example).

.DESCRIPTION
Purpose: Consent phishing and over-permissioned apps give attackers durable access that survives password resets.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-risky-app-consent

Scopes (delegated, read-only): Application.Read.All, Directory.Read.All, AuditLog.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or Cloud Application Administrator / Application Administrator. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID (Free). Entra ID P1 for sign-in logs.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not revoke consent grants, remove app permissions or disable apps.
- Service principal sign-ins come from the beta endpoint, which can change without notice.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
How far back to read service principal sign-ins. Default 30.

.PARAMETER MaxSignIns
Upper limit on sign-in rows. Default 1000.

.EXAMPLE
./risky-app-consent.ps1 -Days 30

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-risky-app-consent
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 30,
    [int]$MaxSignIns = 1000
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Application.Read.All', 'Directory.Read.All', 'AuditLog.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('risky-app-consent-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$tenantId = $context.TenantId

# Step 1: GET /applications (apps registered in this tenant)
$null = Invoke-ReadStep '1-app-registrations' {
    Get-MgApplication -All -Property id,appId,displayName,signInAudience,createdDateTime,requiredResourceAccess |
        Select-Object Id, AppId, DisplayName, SignInAudience, CreatedDateTime, @{n = 'RequestedPermissions'; e = { @($_.RequiredResourceAccess.ResourceAccess).Count } }
}

# Step 2: GET /servicePrincipals?$select=id,appId,displayName,appOwnerOrganizationId,verifiedPublisher
$sps = @(Invoke-ReadStep '2-service-principals' {
    Get-MgServicePrincipal -All -Property id,appId,displayName,appOwnerOrganizationId,verifiedPublisher,servicePrincipalType |
        Select-Object Id, AppId, DisplayName, ServicePrincipalType, AppOwnerOrganizationId,
            @{n = 'ThirdParty'; e = { $_.AppOwnerOrganizationId -and "$($_.AppOwnerOrganizationId)" -ne $tenantId } },
            @{n = 'VerifiedPublisher'; e = { $_.VerifiedPublisher.DisplayName } }
})
$spName = @{}; foreach ($s in $sps) { $spName[$s.Id] = $s.DisplayName }

# Step 3: GET /oauth2PermissionGrants
$null = Invoke-ReadStep '3-delegated-grants' {
    Get-MgOauth2PermissionGrant -All | Select-Object @{n = 'Client'; e = { $spName[$_.ClientId] } }, ClientId, ConsentType, PrincipalId,
        @{n = 'Resource'; e = { $spName[$_.ResourceId] } }, Scope
}

# Step 4: GET /servicePrincipals/{id}/appRoleAssignments (third-party apps only)
$null = Invoke-ReadStep '4-third-party-app-permissions' {
    foreach ($s in $sps | Where-Object ThirdParty) {
        Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $s.Id -All |
            Select-Object @{n = 'App'; e = { $s.DisplayName } }, ResourceDisplayName, AppRoleId, CreatedDateTime
    }
}

# Step 5: GET /beta/auditLogs/signIns?$filter=signInEventTypes/any(t: t eq 'servicePrincipal')
$null = Invoke-ReadStep '5-service-principal-sign-ins' {
    $filter = "signInEventTypes/any(t: t eq 'servicePrincipal') and createdDateTime ge $(Get-UtcStamp -DaysAgo $Days)"
    Get-GraphCollection -Uri "$graph/beta/auditLogs/signIns?`$filter=$([uri]::EscapeDataString($filter))" -MaxItems $MaxSignIns |
        Select-Object @{n = 'createdDateTime'; e = { Get-Field $_ 'createdDateTime' } }, @{n = 'appId'; e = { Get-Field $_ 'appId' } },
            @{n = 'appDisplayName'; e = { Get-Field $_ 'appDisplayName' } }, @{n = 'resourceDisplayName'; e = { Get-Field $_ 'resourceDisplayName' } },
            @{n = 'ipAddress'; e = { Get-Field $_ 'ipAddress' } }, @{n = 'errorCode'; e = { Get-Field (Get-Field $_ 'status') 'errorCode' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
