# Windows equivalent of package.sh: copies the shared scanner, curated data, placement rules, the last generated tier, the app version, the template and the live runner into the function folder.
# Every scanner module goes in, so a new import in scan.py can't be left out.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
Remove-Item -Recurse -Force scanner, data, web, vendor, scripts -ErrorAction SilentlyContinue
New-Item -ItemType Directory scanner, data, web, vendor, scripts | Out-Null
Copy-Item ..\scanner\*.py scanner\
Copy-Item ..\data\curated.json, ..\data\placement.json, ..\data\generated.json, ..\data\version.json data\
Copy-Item ..\web\template.html web\
# the live runner (Phase 8): its code, the pinned MSAL bundle, the shared read-only allow list and the sample responses
Copy-Item -Recurse ..\web\live web\
Copy-Item -Recurse ..\vendor\msal-browser vendor\
Copy-Item ..\scripts\allowlist.json scripts\
Copy-Item -Recurse ..\data\samples data\
Write-Host "Ready. Publish with: func azure functionapp publish <function-app-name>"
