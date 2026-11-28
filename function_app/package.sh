#!/usr/bin/env bash
# Copies the shared scanner, curated data, placement rules, the last generated tier, the app version, the page template and the live runner into the
# function folder before publishing. Every scanner module goes in, so a new import in scan.py can't be left out.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf scanner data web vendor scripts
mkdir -p scanner data web scripts vendor
cp ../scanner/*.py scanner/
cp ../data/curated.json ../data/placement.json ../data/generated.json ../data/version.json data/
cp ../web/template.html web/
# the live runner (Phase 8): its code, the pinned MSAL bundle, the shared read-only allow list and the sample responses
cp -r ../web/live web/
cp -r ../vendor/msal-browser vendor/
cp ../scripts/allowlist.json scripts/
cp -r ../data/samples data/
echo "Ready. Publish with: func azure functionapp publish <function-app-name>"
