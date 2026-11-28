<#
.SYNOPSIS
Checks the scenario scripts and the PowerShell on each scenario step against the installed Microsoft Graph PowerShell SDK.

.DESCRIPTION
Run by tests/test_scripts.py when PowerShell 7 and Microsoft.Graph.Authentication are installed; it can also be run on its own:
  pwsh -NoProfile -File tests/check_scripts.ps1
It never connects to Microsoft Graph. It checks that:
- every script parses;
- every Mg cmdlet exists (Find-MgGraphCommand) and every named parameter exists on it (Get-Command);
- every step's PowerShell uses a cmdlet whose URI matches the step's call, or an Invoke-MgGraphRequest whose URI does;
- PSScriptAnalyzer reports no errors (skipped, and reported as such, when the module isn't installed).
Writes one JSON object to standard output: {errors: [...], analyzer: "ran" | "missing", checked: n}.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication

$errors = [System.Collections.Generic.List[string]]::new()
$authCmdlets = @('Connect-MgGraph', 'Get-MgContext', 'Invoke-MgGraphRequest')
$allow = Get-Content (Join-Path $Root 'scripts/allowlist.json') -Raw | ConvertFrom-Json

function ConvertTo-NormalPath([string]$u) {
    $u = $u.Trim()
    $u = $u -replace '^(GET|POST|PATCH|PUT|DELETE)\s+', ''
    $u = $u -replace '^https://graph\.microsoft\.com', ''
    $u = $u -replace '^/(v1\.0|beta)(?=/)', ''
    $u = $u -replace "\((appId|id)='[^']*'\)", '/{}'
    $u = $u -replace '\{[^}]*\}', '{}'
    $u = ($u -split '[\s?]')[0]
    $u = $u -replace '\([^)]*\)', ''
    $u = $u -replace '/microsoft\.graph\.', '/'
    return $u.TrimEnd('/').ToLowerInvariant()
}

$cmdCache = @{}
function Get-CmdletUri([string]$name) {
    if (-not $cmdCache.ContainsKey($name)) {
        try { $cmdCache[$name] = @(Find-MgGraphCommand -Command $name -ErrorAction Stop) }
        catch { $cmdCache[$name] = @() }
    }
    return $cmdCache[$name]
}

$paramCache = @{}
function Test-CommandParameter([string]$name, [string[]]$params, [string]$where) {
    if (-not $paramCache.ContainsKey($name)) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        $paramCache[$name] = if ($c) { @($c.Parameters.Keys) + @($c.Parameters.Values | ForEach-Object { $_.Aliases }) } else { $null }
    }
    $known = $paramCache[$name]
    if ($null -eq $known) { $errors.Add("${where}: $name is not installed (Get-Command found nothing)"); return }
    foreach ($p in $params) {
        if ($known -notcontains $p) { $errors.Add("${where}: $name has no parameter -$p") }
    }
}

function Get-MgCommandAst($ast) {
    $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -match '^[A-Za-z]+-Mg' }
}

function Test-CommandUse($cmd, [string]$where) {
    $name = $cmd.GetCommandName()
    $params = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    if ($authCmdlets -notcontains $name -and -not (Get-CmdletUri $name).Count) {
        $errors.Add("${where}: Find-MgGraphCommand doesn't know $name")
        return
    }
    Test-CommandParameter $name $params $where
    # Parameter sets: catches parameters that exist but can't be used together (for example -UserId with -Filter).
    $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($cmd, $true)
    foreach ($k in $bound.BindingExceptions.Keys) {
        $msg = $bound.BindingExceptions[$k].BindingException.Message
        if ($msg -notmatch 'positional') { $errors.Add("${where}: $name ${k}: $msg") }
    }
}

# 1. Scripts
$scripts = Get-ChildItem (Join-Path $Root 'scripts/scenarios') -Filter *.ps1
foreach ($f in $scripts) {
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($e in $parseErrors) { $errors.Add("$($f.Name): parse error at line $($e.Extent.StartLineNumber): $($e.Message)") }
    foreach ($cmd in Get-MgCommandAst $ast) { Test-CommandUse $cmd "$($f.Name):$($cmd.Extent.StartLineNumber)" }
}

# 2. Step snippets in curated.json
$curated = Get-Content (Join-Path $Root 'data/curated.json') -Raw | ConvertFrom-Json
$nodes = @{}; foreach ($n in $curated.nodes) { $nodes[$n.id] = $n }
$checked = 0
foreach ($s in $curated.scenarios) {
    $i = 0
    foreach ($st in $s.steps) {
        $i++
        if (-not $st.PSObject.Properties['ps']) { continue }
        $where = "$($s.id) step $i"
        $call = if ($st.PSObject.Properties['call']) { $st.call } else { $nodes[$st.node].path }
        $wants = @($call -split [char]0x00B7 | ForEach-Object { ConvertTo-NormalPath $_ })   # any of "a · b"
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($st.ps, [ref]$tokens, [ref]$parseErrors)
        foreach ($e in $parseErrors) { $errors.Add("${where}: PowerShell doesn't parse: $($e.Message)") }
        $cmds = @(Get-MgCommandAst $ast)
        if (-not $cmds.Count) { $errors.Add("${where}: no Mg cmdlet in '$($st.ps)'"); continue }
        foreach ($cmd in $cmds) { Test-CommandUse $cmd $where }
        $main = $cmds[0]; $name = $main.GetCommandName()
        if ($name -eq 'Invoke-MgGraphRequest') {
            $uriArg = $null
            $els = $main.CommandElements
            for ($k = 0; $k -lt $els.Count - 1; $k++) {
                if ($els[$k] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$k].ParameterName -eq 'Uri') { $uriArg = $els[$k + 1].Extent.Text.Trim('"', "'") }
            }
            if (-not $uriArg) { $errors.Add("${where}: Invoke-MgGraphRequest without -Uri"); continue }
            $uriArg = $uriArg -replace '\$\{?[A-Za-z_]+\}?', '{x}' -replace '`\$', '$'
            if ($wants -notcontains (ConvertTo-NormalPath $uriArg)) { $errors.Add("${where}: URI '$uriArg' doesn't match the step's call '$call'") }
        } else {
            $uris = @(Get-CmdletUri $name | ForEach-Object { ConvertTo-NormalPath $_.URI })
            $okPost = $allow.cmdlets.PSObject.Properties.Name -contains $name -and ($wants -contains (ConvertTo-NormalPath $allow.cmdlets.$name.call))
            # a cmdlet's {id} also takes a literal segment such as a well-known folder name (inbox)
            $hit = @($uris | Where-Object { $rx = '^' + ([regex]::Escape($_) -replace '\\{}', '[^/]+') + '$'; @($wants | Where-Object { $_ -match $rx }).Count }).Count
            if (-not $hit -and -not $okPost) { $errors.Add("${where}: $name serves $($uris -join ', '), not the step's call '$call'") }
        }
        $checked++
    }
}

# 3. PSScriptAnalyzer
$analyzer = 'missing'
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $analyzer = 'ran'
    Import-Module PSScriptAnalyzer
    foreach ($f in $scripts) {
        foreach ($r in Invoke-ScriptAnalyzer -Path $f.FullName -Severity Error) {
            $errors.Add("$($f.Name):$($r.Line): PSScriptAnalyzer $($r.RuleName): $($r.Message)")
        }
    }
}

[pscustomobject]@{ errors = @($errors); analyzer = $analyzer; checked = $checked; scripts = $scripts.Count } | ConvertTo-Json -Depth 3 -Compress
