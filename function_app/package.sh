#!/usr/bin/env bash
# Copies the shared scanner, curated data and page template into the function folder before publishing.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf scanner data web
mkdir -p scanner data web
cp ../scanner/scan.py ../scanner/build_page.py scanner/
cp ../data/curated.json data/
cp ../web/template.html web/
echo "Ready. Publish with: func azure functionapp publish <function-app-name>"
