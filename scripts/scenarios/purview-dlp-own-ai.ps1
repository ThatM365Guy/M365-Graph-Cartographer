#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Security, Microsoft.Graph.Users
<#
.SYNOPSIS
Apply Purview DLP to your own AI apps (read-only example).

.DESCRIPTION
Purpose: Home-grown AI apps can leak data like any other; the Purview APIs let them honour the same DLP and labels as Microsoft 365.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-purview-dlp-own-ai

Scopes (delegated, read-only): User.ReadBasic.All, SensitivityLabel.Read, SecurityAlert.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Security Reader for alerts. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Pay-as-you-go billing for Entra-registered AI apps. Purview DLP licensing for the policies.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not compute protection scopes or send content to processContent (step 2): those calls send content to Purview and changes data, so this script leaves it out.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER UserPrincipalName
The user your AI app acts for.

.PARAMETER Days
How far back to read DLP alerts. Default 30.

.EXAMPLE
./purview-dlp-own-ai.ps1 -UserPrincipalName someone@contoso.com

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Security, Microsoft.Graph.Users -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-purview-dlp-own-ai
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [int]$Days = 30
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('User.ReadBasic.All', 'SensitivityLabel.Read', 'SecurityAlert.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('purview-dlp-own-ai-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /users/{id | userPrincipalName}
$user = Get-MgUser -UserId $UserPrincipalName -Property id,displayName,userPrincipalName,accountEnabled
$null = Invoke-ReadStep '1-user' { $user | Select-Object Id, DisplayName, UserPrincipalName, AccountEnabled }

# Step 2: protectionScopes/compute and processContent send content to Purview, so they are not in this script.

# Step 3: GET /users/{id}/dataSecurityAndGovernance/sensitivityLabels
$null = Invoke-ReadStep '3-labels-for-user' {
    Get-GraphCollection -Uri "$graph/v1.0/users/$($user.Id)/dataSecurityAndGovernance/sensitivityLabels" |
        Select-Object @{n = 'id'; e = { Get-Field $_ 'id' } }, @{n = 'name'; e = { Get-Field $_ 'name' } }, @{n = 'displayName'; e = { Get-Field $_ 'displayName' } },
            @{n = 'priority'; e = { Get-Field $_ 'priority' } }, @{n = 'hasProtection'; e = { Get-Field $_ 'hasProtection' } }
}

# Step 4: GET /security/alerts_v2?$filter=serviceSource eq 'dataLossPrevention'
$null = Invoke-ReadStep '4-dlp-alerts' {
    Get-MgSecurityAlertV2 -Filter "serviceSource eq 'dataLossPrevention' and createdDateTime ge $(Get-UtcStamp -DaysAgo $Days)" -All |
        Select-Object Id, Title, Severity, Status, CreatedDateTime, IncidentId
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
