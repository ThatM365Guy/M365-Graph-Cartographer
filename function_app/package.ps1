# Windows equivalent of package.sh: copies the shared scanner, curated data and template into the function folder.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
Remove-Item -Recurse -Force scanner, data, web -ErrorAction SilentlyContinue
New-Item -ItemType Directory scanner, data, web | Out-Null
Copy-Item ..\scanner\scan.py, ..\scanner\build_page.py scanner\
Copy-Item ..\data\curated.json data\
Copy-Item ..\web\template.html web\
Write-Host "Ready. Publish with: func azure functionapp publish <function-app-name>"
