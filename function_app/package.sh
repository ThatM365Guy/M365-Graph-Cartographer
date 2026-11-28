#!/usr/bin/env bash
# Copies the shared scanner, curated data, placement rules, the last generated tier and the page template into the
# function folder before publishing. Every scanner module goes in, so a new import in scan.py can't be left out.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf scanner data web
mkdir -p scanner data web
cp ../scanner/*.py scanner/
cp ../data/curated.json data/
cp ../web/template.html web/
echo "Ready. Publish with: func azure functionapp publish <function-app-name>"
