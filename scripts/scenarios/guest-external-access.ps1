#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Sites, Microsoft.Graph.Teams, Microsoft.Graph.Users
<#
.SYNOPSIS
Guest and external access review (read-only example).

.DESCRIPTION
Purpose: Guests and shared channels quietly widen who can see your content; access should be reviewed where it is granted.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-guest-external-access

Scopes (delegated, read-only): User.Read.All, AuditLog.Read.All, GroupMember.Read.All, Team.ReadBasic.All, Channel.ReadBasic.All, Sites.Read.All, Files.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Global Reader, or Guest Inviter plus Reports Reader for sign-in activity. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Entra ID (Free). Access reviews need ID Governance or P2.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not remove guests, memberships or sharing.
- Without -SiteId it skips steps 5 and 6 (sites and file permissions).
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER DaysInactive
Guests with no sign-in for this many days are flagged. Default 90.

.PARAMETER SiteId
One or more sites, as a site ID or hostname:/sites/path (for example contoso.sharepoint.com:/sites/Finance). Steps 5 and 6 run only for these sites.

.PARAMETER MaxItemsPerSite
Top-level items checked per site in step 6. Default 200.

.EXAMPLE
./guest-external-access.ps1 -DaysInactive 90 -SiteId contoso.sharepoint.com:/sites/Partners

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Files, Microsoft.Graph.Sites, Microsoft.Graph.Teams, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-guest-external-access
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$DaysInactive = 90,
    [string[]]$SiteId,
    [int]$MaxItemsPerSite = 200
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.Read.All', 'AuditLog.Read.All', 'GroupMember.Read.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'Sites.Read.All', 'Files.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('guest-external-access-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)

# Step 1: GET /users?$filter=userType eq 'Guest'&$select=displayName,mail,signInActivity
$guests = @(Invoke-ReadStep '1-guests' {
    Get-MgUser -Filter "userType eq 'Guest'" -Property id,displayName,mail,userPrincipalName,createdDateTime,externalUserState,signInActivity -All |
        Select-Object Id, DisplayName, Mail, CreatedDateTime, ExternalUserState,
            @{n = 'LastSignIn'; e = { $_.SignInActivity.LastSignInDateTime } },
            @{n = 'Inactive'; e = { -not $_.SignInActivity.LastSignInDateTime -or $_.SignInActivity.LastSignInDateTime -lt $cutoff } }
})

# Step 2: GET /users/{id}/memberOf
$memberships = @(Invoke-ReadStep '2-guest-memberships' {
    foreach ($g in $guests) {
        Get-MgUserMemberOf -UserId $g.Id -All | Where-Object { (Get-Field $_ '@odata.type') -eq '#microsoft.graph.group' } |
            Select-Object @{n = 'Guest'; e = { $g.Mail } }, @{n = 'GroupId'; e = { $_.Id } }, @{n = 'Group'; e = { Get-Field $_ 'displayName' } },
                @{n = 'IsTeam'; e = { @(Get-Field $_ 'resourceProvisioningOptions') -contains 'Team' } }
    }
})

# Step 3: GET /teams/{group-id}
$teamIds = @($memberships | Where-Object IsTeam | ForEach-Object GroupId | Sort-Object -Unique)
$null = Invoke-ReadStep '3-teams-with-guests' {
    foreach ($t in $teamIds) { Get-MgTeam -TeamId $t | Select-Object Id, DisplayName, Visibility, IsArchived, @{n = 'GuestsCanCreateChannels'; e = { $_.GuestSettings.AllowCreateUpdateChannels } } }
}

# Step 4: GET /teams/{id}/channels?$filter=membershipType eq 'shared'
$null = Invoke-ReadStep '4-shared-channels' {
    foreach ($t in $teamIds) {
        Get-MgTeamChannel -TeamId $t -Filter "membershipType eq 'shared'" | Select-Object @{n = 'TeamId'; e = { $t } }, Id, DisplayName, MembershipType, CreatedDateTime
    }
}

if (-not $SiteId) { Write-Skip 'Steps 5 and 6 need -SiteId.' } else {
    # Step 5: GET /sites/{hostname}:/sites/{path}
    $sites = @(Invoke-ReadStep '5-sites' { foreach ($s in $SiteId) { Get-MgSite -SiteId $s | Select-Object Id, DisplayName, WebUrl } })

    # Step 6: GET /drives/{id}/items/{id}/permissions (top-level items of each site's default library)
    $null = Invoke-ReadStep '6-external-permissions' {
        foreach ($s in $sites) {
            $drive = Get-MgSiteDefaultDrive -SiteId $s.Id
            foreach ($item in Get-MgDriveItemChild -DriveId $drive.Id -DriveItemId 'root' -Top $MaxItemsPerSite) {
                foreach ($p in Get-MgDriveItemPermission -DriveId $drive.Id -DriveItemId $item.Id -All) {
                    $email = $p.GrantedToV2.User.AdditionalProperties['email']
                    if ($p.Link.Scope -eq 'anonymous' -or ($email -and @($guests.Mail) -contains $email)) {
                        [pscustomobject]@{ Site = $s.DisplayName; Item = $item.Name; Roles = ($p.Roles -join ';'); LinkScope = $p.Link.Scope
                            GrantedTo = $p.GrantedToV2.User.DisplayName; GrantedToEmail = $email; Expires = $p.ExpirationDateTime }
                    }
                }
            }
        }
    }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
