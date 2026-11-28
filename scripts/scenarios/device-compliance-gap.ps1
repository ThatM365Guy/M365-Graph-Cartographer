#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
Device compliance gap behind Conditional Access (read-only example).

.DESCRIPTION
Purpose: Conditional Access can only require a compliant device if Intune marks the device compliant, so non-compliant devices are either blocked or slipping through.

Scenario: https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-device-compliance-gap

Scopes (delegated, read-only): DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All, Device.Read.All, Policy.Read.All
Application permissions (only for steps that Microsoft Graph serves app-only): none
Entra roles: Intune Administrator or Global Reader for Intune; Conditional Access reads need Global Reader or Security Reader. Global Reader covers the reads in this script; Learn lists the least-privileged role for each call on its API page.
Licence: Intune for compliance; Entra ID P1 for Conditional Access.

What it doesn't do:
- It changes nothing in the tenant. It uses Get-Mg* cmdlets and GET requests only.
- It does not change compliance policies, devices or Conditional Access.
- It sends nothing anywhere except Microsoft Graph. The results stay in CSV files under -OutputFolder on this computer; keep them out of source control.

Tested: not yet
This is an example to read before you run it. It is provided as-is, with no warranty. Run it in a test tenant first.

Each step writes one CSV file named after the step (for example 1-users.csv) into a new dated folder under -OutputFolder. A step that fails (missing permission, licence or role) prints a warning and the script goes on to the next step.

.PARAMETER OutputFolder
Folder for the results. The script creates a dated subfolder in it. Default: .\mgc-output.

.PARAMETER UseExistingConnection
Use the current Connect-MgGraph session instead of signing in again. Use it for an app-only session (certificate) when a step is application-only, or when you have already signed in with the scopes above.

.PARAMETER MaxDevicesToCheck
Non-compliant devices looked up in Entra ID in step 3. Default 100.

.EXAMPLE
./device-compliance-gap.ps1

.NOTES
Microsoft Graph PowerShell SDK v2 on PowerShell 7. Install the modules listed in #Requires first, for example:
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
Written for M365 Graph Cartographer (MGC). Every call matches a step of the scenario on the live site.

.LINK
https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-device-compliance-gap
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path (Get-Location) 'mgc-output'),
    [switch]$UseExistingConnection,
    [int]$MaxDevicesToCheck = 100
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Scopes = @('DeviceManagementConfiguration.Read.All', 'DeviceManagementManagedDevices.Read.All', 'Device.Read.All', 'Policy.Read.All')
if (-not $UseExistingConnection) { Connect-MgGraph -Scopes $Scopes -NoWelcome }
$context = Get-MgContext
if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first or drop -UseExistingConnection.' }
$appOnly = "$($context.AuthType)" -eq 'AppOnly'
$runFolder = Join-Path $OutputFolder ('device-compliance-gap-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# Step 1: GET /deviceManagement/deviceCompliancePolicies
$null = Invoke-ReadStep '1-compliance-policies' {
    Get-MgDeviceManagementDeviceCompliancePolicy -All | Select-Object Id, DisplayName, @{n = 'Platform'; e = { Get-Field $_ '@odata.type' } }, CreatedDateTime, LastModifiedDateTime, Version
}

# Step 2: GET /deviceManagement/managedDevices
$devices = @(Invoke-ReadStep '2-managed-devices' {
    Get-MgDeviceManagementManagedDevice -All | Select-Object Id, DeviceName, OperatingSystem, OSVersion, ComplianceState, ManagementAgent, AzureAdDeviceId,
        UserPrincipalName, LastSyncDateTime, EnrolledDateTime
})

# Step 3: GET /devices?$filter=deviceId eq '{azureADDeviceId}' (what Entra ID, and so Conditional Access, sees)
$null = Invoke-ReadStep '3-entra-view-of-noncompliant' {
    foreach ($d in $devices | Where-Object { $_.ComplianceState -ne 'compliant' -and $_.AzureAdDeviceId -and $_.AzureAdDeviceId -ne '00000000-0000-0000-0000-000000000000' } | Select-Object -First $MaxDevicesToCheck) {
        Get-MgDevice -Filter "deviceId eq '$($d.AzureAdDeviceId)'" -Property id,deviceId,displayName,isCompliant,isManaged,accountEnabled,approximateLastSignInDateTime |
            Select-Object @{n = 'IntuneName'; e = { $d.DeviceName } }, @{n = 'IntuneState'; e = { $d.ComplianceState } }, DisplayName, IsCompliant, IsManaged, AccountEnabled, ApproximateLastSignInDateTime
    }
}

# Step 4: GET /identity/conditionalAccess/policies (policies that require a compliant device)
$null = Invoke-ReadStep '4-policies-requiring-compliance' {
    Get-MgIdentityConditionalAccessPolicy -All | Where-Object { @($_.GrantControls.BuiltInControls) -contains 'compliantDevice' } |
        Select-Object Id, DisplayName, State, @{n = 'Operator'; e = { $_.GrantControls.Operator } }, @{n = 'Controls'; e = { ($_.GrantControls.BuiltInControls) -join ';' } },
            @{n = 'Platforms'; e = { ($_.Conditions.Platforms.IncludePlatforms) -join ';' } }
}

Write-Information "Done. Results: $runFolder" -InformationAction Continue
