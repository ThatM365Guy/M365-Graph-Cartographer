#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports
<#
.SYNOPSIS
Conditional Access coverage and gap analysis (read-only example).

.DESCRIPTION
Purpose: Policies with wide exclusions, report-only policies and apps nobody targeted leave sign-ins with no Conditional Access at all.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-ca-coverage-gaps

Scopes (delegated, read-only): Policy.Read.All, GroupMember.Read.All, AuditLog.Read.All, Policy.Read.ConditionalAccess
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, Security Reader or Conditional Access Administrator; Reports Reader for sign-ins. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P1.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): conditionalAccess/evaluate (step 4, What If)..
- It does not create, change or switch on any policy.
- Step 4 runs only when you pass -WhatIfUserId; conditions you don't set don't match (Learn).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
How far back to read sign-ins no policy applied to. Default 7.

.PARAMETER MaxSignIns
Upper limit on sign-in rows. Default 5000.

.PARAMETER WhatIfUserId
Object ID of a user to test with What If (step 4).

.PARAMETER WhatIfAppId
App ID to test (not a name such as "Office 365"). Default 00000003-0000-0ff1-ce00-000000000000, the app ID in Learn's example.

.PARAMETER DevicePlatform
Device platform for What If. Default windows.

.PARAMETER ClientAppType
Client app type for What If. Default browser.

.EXAMPLE
./ca-coverage-gaps.ps1 -Days 7 -WhatIfUserId 00000000-0000-0000-0000-000000000000

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-ca-coverage-gaps
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 7,
    [int]$MaxSignIns = 5000,
    [string]$WhatIfUserId,
    [string]$WhatIfAppId = '00000003-0000-0ff1-ce00-000000000000',
    [string]$DevicePlatform = 'windows',
    [string]$ClientAppType = 'browser'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('Policy.Read.All', 'GroupMember.Read.All', 'AuditLog.Read.All', 'Policy.Read.ConditionalAccess')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('ca-coverage-gaps-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /identity/conditionalAccess/policies
$policies = @(Invoke-ReadStep '1-policies' {
    Get-MgIdentityConditionalAccessPolicy -All | Select-Object Id, DisplayName, State,
        @{n = 'ReportOnly'; e = { $_.State -eq 'enabledForReportingButNotEnforced' } },
        @{n = 'IncludeUsers'; e = { ($_.Conditions.Users.IncludeUsers) -join ';' } }, @{n = 'ExcludeUsers'; e = { ($_.Conditions.Users.ExcludeUsers) -join ';' } },
        @{n = 'IncludeGroups'; e = { ($_.Conditions.Users.IncludeGroups) -join ';' } }, @{n = 'ExcludeGroups'; e = { ($_.Conditions.Users.ExcludeGroups) -join ';' } },
        @{n = 'IncludeRoles'; e = { ($_.Conditions.Users.IncludeRoles) -join ';' } }, @{n = 'IncludeApplications'; e = { ($_.Conditions.Applications.IncludeApplications) -join ';' } },
        @{n = 'GrantControls'; e = { ($_.GrantControls.BuiltInControls) -join ';' } }, @{n = 'AuthenticationStrength'; e = { $_.GrantControls.AuthenticationStrength.Id } }
})

# Step 2: GET /groups/{id}/members (excluded groups, including break-glass accounts)
$null = Invoke-ReadStep '2-excluded-group-members' {
    foreach ($g in $policies | ForEach-Object { $_.ExcludeGroups -split ';' } | Where-Object { $_ } | Sort-Object -Unique) {
        Get-MgGroupMember -GroupId $g -All | Select-Object @{n = 'GroupId'; e = { $g } }, Id, @{n = 'Type'; e = { Get-Field $_ '@odata.type' } },
            @{n = 'DisplayName'; e = { Get-Field $_ 'displayName' } }, @{n = 'UserPrincipalName'; e = { Get-Field $_ 'userPrincipalName' } }
    }
}

# Step 3: GET /auditLogs/signIns?$filter=conditionalAccessStatus eq 'notApplied' and createdDateTime ge {date}
$null = Invoke-ReadStep '3-sign-ins-no-policy-applied' {
    Get-MgAuditLogSignIn -Filter "conditionalAccessStatus eq 'notApplied' and createdDateTime ge $(Get-UtcStamp -DaysAgo $Days)" -Top $MaxSignIns |
        Group-Object UserPrincipalName, AppDisplayName, ClientAppUsed | Sort-Object Count -Descending |
        Select-Object @{n = 'UserPrincipalName'; e = { $_.Group[0].UserPrincipalName } }, @{n = 'App'; e = { $_.Group[0].AppDisplayName } },
            @{n = 'ClientApp'; e = { $_.Group[0].ClientAppUsed } }, @{n = 'SignIns'; e = { $_.Count } }, @{n = 'Latest'; e = { ($_.Group.CreatedDateTime | Measure-Object -Maximum).Maximum } }
}

# Step 4: POST /identity/conditionalAccess/evaluate (What If) (read-only, uses POST)
if ($WhatIfUserId) {
    $null = Invoke-ReadStep '4-what-if' {
        $body = @{
            signInIdentity = @{ '@odata.type' = '#microsoft.graph.userSignIn'; userId = $WhatIfUserId }
            signInContext = @{ '@odata.type' = '#microsoft.graph.applicationContext'; includeApplications = @($WhatIfAppId) }
            signInConditions = @{ devicePlatform = $DevicePlatform; clientAppType = $ClientAppType }
            appliedPoliciesOnly = $false
        }
        $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/identity/conditionalAccess/evaluate" -Body $body -OutputType PSObject  # read-only, uses POST
        @(Get-Field $r 'value') | Select-Object @{n = 'id'; e = { Get-Field $_ 'id' } }, @{n = 'displayName'; e = { Get-Field $_ 'displayName' } },
            @{n = 'state'; e = { Get-Field $_ 'state' } }, @{n = 'policyApplies'; e = { Get-Field $_ 'policyApplies' } }, @{n = 'analysisReasons'; e = { Get-Field $_ 'analysisReasons' } }
    }
} else { Write-Skip 'Step 4 needs -WhatIfUserId.' }

# Step 5: GET /policies/crossTenantAccessPolicy/partners (inbound trust for guests)
$null = Invoke-ReadStep '5-cross-tenant-trust' {
    $default = Get-MgPolicyCrossTenantAccessPolicyDefault
    [pscustomobject]@{ TenantId = 'default'; MfaAccepted = $default.InboundTrust.IsMfaAccepted; CompliantDeviceAccepted = $default.InboundTrust.IsCompliantDeviceAccepted
        HybridJoinedDeviceAccepted = $default.InboundTrust.IsHybridAzureAdJoinedDeviceAccepted }
    Get-MgPolicyCrossTenantAccessPolicyPartner -All | ForEach-Object {
        [pscustomobject]@{ TenantId = $_.TenantId; MfaAccepted = $_.InboundTrust.IsMfaAccepted; CompliantDeviceAccepted = $_.InboundTrust.IsCompliantDeviceAccepted
            HybridJoinedDeviceAccepted = $_.InboundTrust.IsHybridAzureAdJoinedDeviceAccepted }
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
