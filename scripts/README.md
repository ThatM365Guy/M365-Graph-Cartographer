# Scenario scripts

One read-only PowerShell script for each scenario in M365 Graph Cartographer, in `scenarios/<scenario-id>.ps1`. Each one runs its scenario's read steps from start to finish and writes one CSV file per step to a dated folder on your computer.

These are examples to read before you run them. They are provided as-is, with no warranty. Run them in a test tenant first.

## What "read-only" means here

- `Connect-MgGraph` asks only for delegated read permissions (`.Read`, `.ReadBasic`, never `ReadWrite`).
- Only `Get-Mg*` cmdlets and `Invoke-MgGraphRequest -Method GET` are used, plus the few read calls that need POST. Those are listed in [`allowlist.json`](allowlist.json) and every use is labelled `# read-only, uses POST`: advanced hunting, audit log searches, Conditional Access What If, Microsoft Search and reading a file's sensitivity labels.
- Steps that change data (revoking sessions, applying labels, creating cases or retention events) are left out, and each script's header says so.
- Nothing is sent anywhere except Microsoft Graph. Results stay in the `-OutputFolder` you choose (default `.\mgc-output`). Keep them out of source control.

A few steps are application-only in Microsoft Graph (for example listing every site, or Copilot interaction export). In a delegated session the script skips them with a message. To run them, connect app-only first (certificate) and add `-UseExistingConnection`.

## Running one

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
cd scripts/scenarios
Get-Help ./posture-change-review.ps1 -Full
./posture-change-review.ps1
```

Each script's header lists its purpose, scopes, Entra roles, licence, parameters (with safe defaults), what it doesn't do and a link to the scenario on the live site.

## Checks

`python -m unittest discover tests` runs them all:

- `tests/test_scripts.py`: one script per scenario; the header; the read-only guard (fails on `New-`, `Set-`, `Update-`, `Remove-` or `Add-` cmdlets, any other non-`Get-` Mg cmdlet that isn't on the allow list, any non-GET request that isn't on the allow list, other network commands and non-Graph URLs); scopes are read-only and are real Graph permission names.
- `tests/check_scripts.ps1` (run by the tests when PowerShell 7 and the Microsoft.Graph modules are installed): every Mg cmdlet exists (`Find-MgGraphCommand`), every parameter exists and the parameter sets bind, every step's PowerShell on the page matches the step's HTTP call, and PSScriptAnalyzer reports no errors (skipped when PSScriptAnalyzer isn't installed).

## Marking a script as tested

A script counts as tested only after the owner has run it in their own dev tenant. Change its header line from `Tested: not yet` to `Tested: YYYY-MM-DD` (the date it ran cleanly). The page shows the date next to the download link.
