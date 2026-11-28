#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance, Microsoft.Graph.Reports, Microsoft.Graph.Users
<#
.SYNOPSIS
Privileged access review (read-only example).

.DESCRIPTION
Purpose: Standing admin roles are the biggest identity risk; a review should cover active and eligible assignments and how they are used.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-privileged-access-review

Scopes (delegated, read-only): RoleManagement.Read.Directory, RoleEligibilitySchedule.Read.Directory, User.Read.All, AuditLog.Read.All, AdministrativeUnit.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or Privileged Role Administrator. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID P2 or ID Governance for PIM. Entra ID P1 for sign-in logs.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not remove role assignments or change PIM settings.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER Days
How far back to read sign-ins. Default 30.

.PARAMETER MaxSignInsPerUser
Sign-ins to read per privileged user. Default 20.

.EXAMPLE
./privileged-access-review.ps1 -Days 30

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance, Microsoft.Graph.Reports, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-privileged-access-review
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$Days = 30,
    [int]$MaxSignInsPerUser = 20
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('RoleManagement.Read.Directory', 'RoleEligibilitySchedule.Read.Directory', 'User.Read.All', 'AuditLog.Read.All', 'AdministrativeUnit.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('privileged-access-review-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$since = Get-UtcStamp -DaysAgo $Days
$roleNames = @{}
try { Get-MgRoleManagementDirectoryRoleDefinition -All | ForEach-Object { $roleNames[$_.Id] = $_.DisplayName } } catch { Write-Warning "Role names: $($_.Exception.Message)" }

# Step 1: GET /directoryRoles?$expand=members
$active = @(Invoke-ReadStep '1-active-role-members' {
    foreach ($r in Get-MgDirectoryRole -ExpandProperty members -All) {
        foreach ($m in @($r.Members)) {
            [pscustomobject]@{ Role = $r.DisplayName; RoleTemplateId = $r.RoleTemplateId; MemberId = $m.Id
                MemberType = Get-Field $m '@odata.type'; MemberName = Get-Field $m 'displayName'; MemberUpn = Get-Field $m 'userPrincipalName' }
        }
    }
})

# Step 2: GET /roleManagement/directory/roleEligibilitySchedules
$eligible = @(Invoke-ReadStep '2-eligible-assignments' {
    Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All | Select-Object PrincipalId,
        @{n = 'Role'; e = { $roleNames[$_.RoleDefinitionId] } }, RoleDefinitionId, DirectoryScopeId, MemberType, Status,
        @{n = 'Start'; e = { $_.ScheduleInfo.StartDateTime } }, @{n = 'End'; e = { $_.ScheduleInfo.Expiration.EndDateTime } }
})

# Step 3: GET /users/{id}?$select=accountEnabled,onPremisesSyncEnabled,signInActivity
$userIds = @($active | Where-Object MemberType -eq '#microsoft.graph.user' | ForEach-Object MemberId) + @($eligible | ForEach-Object PrincipalId) | Sort-Object -Unique
$users = @(Invoke-ReadStep '3-privileged-users' {
    foreach ($id in $userIds) {
        try {
            $u = Get-MgUser -UserId $id -Property id,displayName,userPrincipalName,accountEnabled,onPremisesSyncEnabled,signInActivity
            [pscustomobject]@{ Id = $u.Id; DisplayName = $u.DisplayName; UserPrincipalName = $u.UserPrincipalName; AccountEnabled = $u.AccountEnabled
                SyncedFromOnPremises = [bool]$u.OnPremisesSyncEnabled; LastSignIn = $u.SignInActivity.LastSignInDateTime
                LastNonInteractiveSignIn = $u.SignInActivity.LastNonInteractiveSignInDateTime }
        } catch { Write-Verbose "Not a user or not readable: $id" }
    }
})

# Step 4: GET /directory/administrativeUnits/{id}/scopedRoleMembers
$null = Invoke-ReadStep '4-admin-unit-scoped-roles' {
    foreach ($au in Get-MgDirectoryAdministrativeUnit -All) {
        foreach ($m in Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $au.Id -All) {
            [pscustomobject]@{ AdministrativeUnit = $au.DisplayName; Role = $roleNames[$m.RoleId]; RoleId = $m.RoleId
                MemberId = $m.RoleMemberInfo.Id; MemberName = $m.RoleMemberInfo.DisplayName }
        }
    }
}

# Step 5: GET /auditLogs/signIns?$filter=userId eq '{id}'
$null = Invoke-ReadStep '5-privileged-sign-ins' {
    foreach ($u in $users) {
        Get-MgAuditLogSignIn -Filter "userId eq '$($u.Id)' and createdDateTime ge $since" -Top $MaxSignInsPerUser |
            Select-Object @{n = 'User'; e = { $u.UserPrincipalName } }, CreatedDateTime, AppDisplayName, IPAddress, ClientAppUsed,
                ConditionalAccessStatus, @{n = 'ErrorCode'; e = { $_.Status.ErrorCode } }, @{n = 'Country'; e = { $_.Location.CountryOrRegion } }
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
