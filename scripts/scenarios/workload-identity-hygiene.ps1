#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
Workload identity hygiene: expiring secrets, unused and over-permissioned apps (read-only example).

.DESCRIPTION
Purpose: Forgotten app credentials and permissions outlive the projects that needed them; expired secrets break things and long-lived ones get stolen.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-workload-identity-hygiene

Scopes (delegated, read-only): Application.Read.All, AuditLog.Read.All, IdentityRiskyServicePrincipal.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or Cloud Application Administrator. Reports Reader or Security Reader for the credential sign-in report. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID Free; Entra ID P1 or P2 for credential last use.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not remove credentials, add owners or remove permissions.
- Credential last use comes from the beta appCredentialSignInActivities report.
- Reading keyCredentials is throttled (Learn: 150 requests a minute per tenant).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER DaysUntilExpiry
Credentials ending within this many days are marked expiring. Default 30.

.PARAMETER DaysUnused
Credentials not used for this many days are marked unused. Default 90.

.PARAMETER MaxApps
Upper limit on this tenant's apps whose permissions are read in step 5. Default 500.

.EXAMPLE
./workload-identity-hygiene.ps1 -DaysUntilExpiry 30

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-workload-identity-hygiene
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$DaysUntilExpiry = 30,
    [int]$DaysUnused = 90,
    [int]$MaxApps = 500
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Application.Read.All', 'AuditLog.Read.All', 'IdentityRiskyServicePrincipal.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('workload-identity-hygiene-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

function ConvertTo-CredentialRow {
    param($Owner, [string]$Kind, $Credentials, [string]$Type)
    foreach ($c in @($Credentials)) {
        if ($null -eq $c) { continue }
        $left = if ($c.EndDateTime) { [math]::Floor(($c.EndDateTime.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays) } else { $null }
        [pscustomobject]@{ Kind = $Kind; Name = $Owner.DisplayName; AppId = $Owner.AppId; ObjectId = $Owner.Id; Type = $Type; KeyId = $c.KeyId
            CredentialName = $c.DisplayName; EndDateTime = $c.EndDateTime; DaysLeft = $left
            State = if ($null -eq $left) { 'no end date' } elseif ($left -lt 0) { 'expired' } elseif ($left -le $DaysUntilExpiry) { 'expiring' } else { 'ok' } }
    }
}

$tenantId = $context.TenantId

# Step 1: GET /applications?$select=id,appId,displayName,passwordCredentials,keyCredentials
$null = Invoke-ReadStep '1-app-credentials' {
    foreach ($a in Get-MgApplication -All -Property id,appId,displayName,passwordCredentials,keyCredentials) {
        ConvertTo-CredentialRow $a 'application' $a.PasswordCredentials 'secret'
        ConvertTo-CredentialRow $a 'application' $a.KeyCredentials 'certificate'
    }
}

# Step 2: the same for service principals
$sps = @(Get-MgServicePrincipal -All -Property id,appId,displayName,appOwnerOrganizationId,passwordCredentials,keyCredentials)
$null = Invoke-ReadStep '2-service-principal-credentials' {
    foreach ($s in $sps) {
        ConvertTo-CredentialRow $s 'servicePrincipal' $s.PasswordCredentials 'secret'
        ConvertTo-CredentialRow $s 'servicePrincipal' $s.KeyCredentials 'certificate'
    }
}

# Step 3: GET /applications?$filter=owners/$count eq 0 or owners/$count eq 1&$count=true (ConsistencyLevel: eventual)
$null = Invoke-ReadStep '3-apps-with-fewer-than-two-owners' {
    Get-MgApplication -Filter 'owners/$count eq 0 or owners/$count eq 1' -CountVariable fewOwners -ConsistencyLevel eventual -All -Property id,appId,displayName,createdDateTime |
        Select-Object Id, AppId, DisplayName, CreatedDateTime
}

# Step 4: GET /beta/reports/appCredentialSignInActivities
$unusedBefore = (Get-Date).ToUniversalTime().AddDays(-$DaysUnused)
$null = Invoke-ReadStep '4-credential-last-use' {
    Get-GraphCollection -Uri "$graph/beta/reports/appCredentialSignInActivities" | ForEach-Object {
        $last = Get-Field (Get-Field $_ 'signInActivity') 'lastSignInDateTime'
        [pscustomobject]@{ appId = Get-Field $_ 'appId'; keyId = Get-Field $_ 'keyId'; keyType = Get-Field $_ 'keyType'; credentialOrigin = Get-Field $_ 'credentialOrigin'
            expirationDateTime = Get-Field $_ 'expirationDateTime'; lastSignIn = $last; unused = (-not $last -or ([datetime]$last).ToUniversalTime() -lt $unusedBefore) }
    }
}

# Step 5: GET /servicePrincipals/{id}/appRoleAssignments (application permissions held by this tenant's own apps)
$null = Invoke-ReadStep '5-app-permissions' {
    foreach ($s in $sps | Where-Object { "$($_.AppOwnerOrganizationId)" -eq $tenantId } | Select-Object -First $MaxApps) {
        Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $s.Id -All | Select-Object @{n = 'App'; e = { $s.DisplayName } }, @{n = 'AppId'; e = { $s.AppId } }, ResourceDisplayName, AppRoleId, CreatedDateTime
    }
}

# Step 6: GET /identityProtection/riskyServicePrincipals
$null = Invoke-ReadStep '6-risky-service-principals' {
    Get-MgRiskyServicePrincipal -All | Select-Object AppId, DisplayName, RiskLevel, RiskState, RiskLastUpdatedDateTime
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
