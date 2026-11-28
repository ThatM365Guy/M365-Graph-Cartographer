#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Files, Microsoft.Graph.Users
<#
.SYNOPSIS
Secure offboarding (read-only example).

.DESCRIPTION
Purpose: A leaver's tokens, group access, app access, files and devices must all be cut off, not just the account disabled.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-secure-offboarding

Scopes (delegated, read-only): User.Read.All, GroupMember.Read.All, Directory.Read.All, Files.Read.All, Device.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or User Administrator for the user reads. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID (Free). Intune for device actions.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not block sign-in or revoke sessions (step 1), remove group memberships or app assignments, or move files: those steps changes data, so this script leaves it out.
- Reading another user's OneDrive with delegated access needs access to that OneDrive; otherwise run it app-only (Files.Read.All).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER UserPrincipalName
The user to look at, for example someone@contoso.com.

.EXAMPLE
./secure-offboarding.ps1 -UserPrincipalName leaver@contoso.com

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Files, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-secure-offboarding
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [Parameter(Mandatory)][string]$UserPrincipalName
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.Read.All', 'GroupMember.Read.All', 'Directory.Read.All', 'Files.Read.All', 'Device.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('secure-offboarding-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$user = Get-MgUser -UserId $UserPrincipalName -Property id,displayName,userPrincipalName,accountEnabled
$userId = $user.Id

# Step 1: block sign-in and revoke sessions changes data, so it is not in this script.
$null = Invoke-ReadStep '1-user' { $user | Select-Object Id, DisplayName, UserPrincipalName, AccountEnabled }

# Step 2: GET /users/{id}/memberOf
$null = Invoke-ReadStep '2-memberships' {
    Get-MgUserMemberOf -UserId $userId -All | Select-Object Id,
        @{n = 'Type'; e = { Get-Field $_ '@odata.type' } }, @{n = 'DisplayName'; e = { Get-Field $_ 'displayName' } },
        @{n = 'IsAssignableToRole'; e = { Get-Field $_ 'isAssignableToRole' } }
}

# Step 3: GET /users/{id}/appRoleAssignments
$null = Invoke-ReadStep '3-app-assignments' {
    Get-MgUserAppRoleAssignment -UserId $userId -All | Select-Object ResourceDisplayName, ResourceId, AppRoleId, PrincipalType, CreatedDateTime
}

# Step 4: GET /users/{id}/drive
$null = Invoke-ReadStep '4-onedrive' {
    Get-MgUserDefaultDrive -UserId $userId | Select-Object Id, DriveType, WebUrl, LastModifiedDateTime,
        @{n = 'QuotaUsedBytes'; e = { $_.Quota.Used } }
}

# Step 5: GET /users/{id}/ownedDevices
$null = Invoke-ReadStep '5-owned-devices' {
    Get-MgUserOwnedDevice -UserId $userId -All | Select-Object Id,
        @{n = 'DisplayName'; e = { Get-Field $_ 'displayName' } }, @{n = 'OperatingSystem'; e = { Get-Field $_ 'operatingSystem' } },
        @{n = 'ApproximateLastSignInDateTime'; e = { Get-Field $_ 'approximateLastSignInDateTime' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
