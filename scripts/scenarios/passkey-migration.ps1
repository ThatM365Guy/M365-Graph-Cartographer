#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports
<#
.SYNOPSIS
Phishing-resistant MFA migration tracking (passkeys) (read-only example).

.DESCRIPTION
Purpose: Passkeys and other phishing-resistant methods only protect users who have registered them and are required to use them.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-passkey-migration

Scopes (delegated, read-only): AuditLog.Read.All, Policy.Read.AuthenticationMethod, Policy.Read.All, UserAuthenticationMethod.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader or Authentication Policy Administrator for the policies; Reports Reader for registration details. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P1 or P2 for the registration report and Conditional Access.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not change the authentication methods policy, strengths or Conditional Access, and does not register or remove methods.
- Disabled users aren't in the registration report (Learn).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER MaxUsers
Users without passwordless sign-in whose methods are read in step 5. Default 25.

.EXAMPLE
./passkey-migration.ps1

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-passkey-migration
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$MaxUsers = 25
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('AuditLog.Read.All', 'Policy.Read.AuthenticationMethod', 'Policy.Read.All', 'UserAuthenticationMethod.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('passkey-migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /reports/authenticationMethods/userRegistrationDetails?$filter=isPasswordlessCapable eq false
$notReady = @(Invoke-ReadStep '1-not-passwordless' {
    Get-MgReportAuthenticationMethodUserRegistrationDetail -Filter 'isPasswordlessCapable eq false' -All |
        Select-Object Id, UserPrincipalName, UserType, IsAdmin, IsMfaRegistered, IsPasswordlessCapable, @{n = 'Methods'; e = { ($_.MethodsRegistered) -join ';' } }
})

# Step 2: GET /policies/authenticationMethodsPolicy
$null = Invoke-ReadStep '2-methods-policy' {
    $p = Get-MgPolicyAuthenticationMethodPolicy
    foreach ($c in @($p.AuthenticationMethodConfigurations)) { [pscustomobject]@{ Method = $c.Id; State = $c.State } }
}

# Step 3: GET /policies/authenticationStrengthPolicies
$strengths = @(Invoke-ReadStep '3-authentication-strengths' {
    Get-MgPolicyAuthenticationStrengthPolicy -All | Select-Object Id, DisplayName, PolicyType, @{n = 'AllowedCombinations'; e = { ($_.AllowedCombinations) -join ';' } }
})
$strengthName = @{}; foreach ($s in $strengths) { $strengthName[$s.Id] = $s.DisplayName }

# Step 4: GET /identity/conditionalAccess/policies (policies that require a strength, and who they leave out)
$null = Invoke-ReadStep '4-policies-requiring-strength' {
    Get-MgIdentityConditionalAccessPolicy -All | Where-Object { $_.GrantControls.AuthenticationStrength.Id } |
        Select-Object Id, DisplayName, State, @{n = 'Strength'; e = { $strengthName[$_.GrantControls.AuthenticationStrength.Id] } },
            @{n = 'IncludeUsers'; e = { ($_.Conditions.Users.IncludeUsers) -join ';' } }, @{n = 'ExcludeUsers'; e = { ($_.Conditions.Users.ExcludeUsers) -join ';' } },
            @{n = 'ExcludeGroups'; e = { ($_.Conditions.Users.ExcludeGroups) -join ';' } }
}

# Step 5: GET /users/{id}/authentication/methods (a few stragglers; Learn advises against this for the whole population)
$null = Invoke-ReadStep '5-straggler-methods' {
    foreach ($u in $notReady | Where-Object { $_.UserType -eq 'member' } | Select-Object -First $MaxUsers) {
        Get-MgUserAuthenticationMethod -UserId $u.Id | Select-Object @{n = 'User'; e = { $u.UserPrincipalName } }, @{n = 'Method'; e = { Get-Field $_ '@odata.type' } }
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
