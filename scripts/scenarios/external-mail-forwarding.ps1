#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Mail, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Mail forwarding to external addresses (read-only example).

.DESCRIPTION
Purpose: Auto-forwarding is a classic exfiltration route, and it can be set in places Graph can't see.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-external-mail-forwarding

Scopes (delegated, read-only): User.Read, User.Read.All, MailboxSettings.Read, SecurityAlert.Read.All, ThreatHunting.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): MailboxSettings.Read (step 2, for other users' inbox rules); Organization.Read.All to read the tenant's verified domains in an app-only session
Entra roles: Security Reader for alerts and hunting. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Exchange Online. Defender XDR for alerts and hunting.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only, plus these read-only calls that use POST (allow list in scripts/allowlist.json): runHuntingQuery (step 5)..
- It does not read mailbox forwarding (ForwardingSmtpAddress), the outbound spam policy, remote domains or transport rules: those are in Exchange Online PowerShell only (step 3).
- It does not remove rules.
- With delegated access Graph returns another user's mailbox data only if you can open that mailbox; otherwise run it app-only (application permission MailboxSettings.Read) with -UseExistingConnection.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER MaxMailboxes
Mailboxes whose inbox rules are read. Default 200.

.PARAMETER InternalDomain
Your own mail domains. Without it the script uses the tenant's verified domains (GET /organization, which User.Read can read). A subdomain of an internal domain counts as internal. Guests' addresses never make a domain internal.

.PARAMETER Days
How far back to look for alerts and outbound mail. Default 7.

.EXAMPLE
./external-mail-forwarding.ps1 -MaxMailboxes 500

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Mail, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-external-mail-forwarding
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$MaxMailboxes = 200,
    [string[]]$InternalDomain,
    [int]$Days = 7
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.Read', 'User.Read.All', 'MailboxSettings.Read', 'SecurityAlert.Read.All', 'ThreatHunting.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('external-mail-forwarding-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

function Invoke-HuntingQuery {
    # Advanced hunting (read-only, uses POST). Returns the result rows.
    param([Parameter(Mandatory)][string]$Query, [string]$Timespan = 'P30D')
    $r = Invoke-MgGraphRequest -Method POST -Uri "$graph/v1.0/security/runHuntingQuery" -Body @{ Query = $Query; Timespan = $Timespan } -OutputType PSObject  # read-only, uses POST
    @(Get-Field $r 'results')
}

$since = Get-UtcStamp -DaysAgo $Days

# Step 1: GET /users?$filter=mail ne null&$select=id,mail
$users = @(Invoke-ReadStep '1-mailboxes' {
    Get-MgUser -Filter 'mail ne null' -Property id,mail,userPrincipalName -CountVariable mailUsers -ConsistencyLevel eventual -All | Select-Object Id, Mail, UserPrincipalName
})

# Internal domains: -InternalDomain, or else the tenant's verified domains (GET /organization?$select=verifiedDomains).
# Not the users' mail domains: guests have mail addresses too, and those domains are external.
if (-not $InternalDomain) {
    try {
        $InternalDomain = @(Get-MgOrganization -Property verifiedDomains | ForEach-Object { $_.VerifiedDomains.Name } | Where-Object { $_ })
    } catch { Write-Warning "Verified domains: $($_.Exception.Message)" }
}
$InternalDomain = @($InternalDomain | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)

function Test-InternalAddress {
    # True when the address is in an internal domain or a subdomain of one (mail.contoso.com under contoso.com).
    param([string]$Address)
    $domain = ($Address -split '@')[-1].ToLowerInvariant()
    foreach ($d in $InternalDomain) { if ($domain -eq $d -or $domain.EndsWith(".$d")) { return $true } }
    return $false
}

# Step 2: GET /users/{id}/mailFolders/inbox/messageRules (rules that send mail outside your domains)
if (-not $InternalDomain) { Write-Skip 'Step 2 needs your internal domains. Pass -InternalDomain, for example -InternalDomain contoso.com, contoso.co.uk.' } else {
    $null = Invoke-ReadStep '2-forwarding-rules' {
        foreach ($u in $users | Select-Object -First $MaxMailboxes) {
            try { $rules = @(Get-MgUserMailFolderMessageRule -UserId $u.Id -MailFolderId 'inbox' -All) } catch { Write-Verbose "$($u.Mail): $($_.Exception.Message)"; continue }
            foreach ($r in $rules) {
                $targets = @($r.Actions.ForwardTo.EmailAddress.Address) + @($r.Actions.ForwardAsAttachmentTo.EmailAddress.Address) + @($r.Actions.RedirectTo.EmailAddress.Address) | Where-Object { $_ }
                $external = @($targets | Where-Object { -not (Test-InternalAddress $_) })
                if ($external.Count) {
                    [pscustomobject]@{ Mailbox = $u.Mail; Rule = $r.DisplayName; Enabled = $r.IsEnabled; ExternalTargets = $external -join ';' }
                }
            }
        }
    }
}

# Step 3: outside Graph
Write-Skip 'Step 3: mailbox forwarding, outbound spam policy, remote domains and transport rules are in Exchange Online PowerShell (Get-Mailbox, Get-HostedOutboundSpamFilterPolicy, Get-RemoteDomain, Get-TransportRule).'

# Step 4: GET /security/alerts_v2?$filter=title has 'forward'
$null = Invoke-ReadStep '4-forwarding-alerts' {
    Get-MgSecurityAlertV2 -Filter "createdDateTime ge $since" -All | Where-Object { $_.Title -match 'forward' } |
        Select-Object Id, Title, Severity, Status, ServiceSource, CreatedDateTime
}

# Step 5: POST /security/runHuntingQuery (EmailEvents, outbound) (read-only, uses POST)
$null = Invoke-ReadStep '5-outbound-mail-by-domain' {
    Invoke-HuntingQuery -Timespan "P$($Days)D" -Query "EmailEvents | where EmailDirection == 'Outbound' | extend RecipientDomain = tostring(split(RecipientEmailAddress, '@')[1]) | summarize Messages = count() by SenderFromAddress, RecipientDomain | top 200 by Messages" |
        Select-Object SenderFromAddress, RecipientDomain, Messages
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
