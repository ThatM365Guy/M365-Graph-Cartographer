# Windows equivalent of package.sh: copies the shared scanner, curated data and template into the function folder.
# Every scanner module goes in, so a new import in scan.py can't be left out.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
Remove-Item -Recurse -Force scanner, data, web -ErrorAction SilentlyContinue
New-Item -ItemType Directory scanner, data, web | Out-Null
Copy-Item ..\scanner\*.py scanner\
Copy-Item ..\data\curated.json data\
Copy-Item ..\web\template.html web\
Write-Host "Ready. Publish with: func azure functionapp publish <function-app-name>"
