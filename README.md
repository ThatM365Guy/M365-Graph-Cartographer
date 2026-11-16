# M365 Graph Cartographer (MGC)

M365 Graph Cartographer (MGC) is an interactive map of Microsoft Graph that opens like a fan. A scheduled scanner keeps it current by reading Microsoft's published Graph schema. Graph sits in the middle with the services on a ring round it; open a service to see its sub-services, and a sub-service to see the APIs you call. Hover over any node to see its endpoint, its least-privileged permissions and its main limitation. Click it for the full notes: licensing, limitations, how to map it, its connections, and (after a scan) its live schema.

Phase 1 covers the simpler workloads broadly: identity, Outlook, files and sites, Teams, tasks, reports and security. Compliance & Purview is stubbed and will be covered in depth in phase 2.

## How it fits together

```
 data/curated.json  ──────┐   hand-written notes, in Git (the only file people edit)
                          ▼
 Graph $metadata ──▶ scanner/scan.py ──▶ data/graph-map.json  (curated + scan results)
 (v1.0 and beta)          │                data/changelog.json (what moved between scans)
 Graph permissions ───────┘  (optional)
                          ▼
              scanner/build_page.py ──▶ dist/index.html  (single file, data embedded)

 Runs on a schedule in either:
   A. Azure Function (timer + HTTP trigger) ──▶ Storage static website ($web)
   B. GitHub Actions (weekly cron)          ──▶ commit + GitHub Pages
```

Design rules:

- **Curated and generated data are kept apart.** The scanner never edits `curated.json`, so a scan can't overwrite anyone's notes. It writes `graph-map.json` next to it.
- **The scan is anonymous.** `$metadata` is public, so the core scan needs no app registration and no tenant access. The page holds no tenant data, so it's safe to host publicly.
- **The permission check is optional.** If it's switched on, the scanner reads every Graph permission name from the Microsoft Graph service principal and flags any name in the notes that no longer exists. This needs `Application.Read.All`.
- **One self-contained page.** No API calls at runtime, so it works as a static site, a SharePoint embed, a Claude artifact, or a file opened from disk.
- **Standard library only.** `scan.py` and `build_page.py` need nothing beyond Python 3.10+, so they behave the same locally, in Actions and in Functions.

## What each scan does

1. Downloads `https://graph.microsoft.com/v1.0/$metadata` and `/beta/$metadata`, and parses them with `iterparse` (the beta document is large).
2. For every node with an `entityType`, records whether it is in **v1.0**, **beta only**, or **not found**. It also records the full property and relationship lists (including inherited ones), plus anything that exists only in beta.
3. For every curated link, checks that the navigation property or bound action still exists.
4. **Discovers new links**: any navigation property between two resources on the map that isn't curated yet is added as a dashed "found by scanner" link.
5. Compares the results with the previous scan and logs the changes, for example *"Sensitivity label: moved from beta only to v1.0"* or *"User: new v1.0 property 'employeeLeaveDateTime'"*. Nodes that changed in the last 45 days get a red dot on the map.
6. Optionally checks permission names and logs any newly published permissions related to the ones on the map.

## Run it locally

```bash
python -m unittest discover tests                 # offline tests against small CSDL fixtures
python scanner/scan.py                             # live scan (needs internet access to graph.microsoft.com)
python scanner/scan.py --no-scan                   # merge curated edits only, keep the last scan results
GRAPH_TOKEN=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv) \
  python scanner/scan.py --permissions             # also check permission names
python scanner/build_page.py                       # writes dist/index.html
```

## Deploy option A: Azure Function and a static website

The Function runs weekly (Mondays 05:30 UTC by default) and can also be started on demand with `POST /api/scan`. It writes `index.html`, `graph-map.json` and `changelog.json` to the storage account's `$web` container.

```bash
RG=rg-mgc; LOC=uksouth; SA=stmgc$RANDOM; FA=func-mgc-$RANDOM

az group create -n $RG -l $LOC
az storage account create -n $SA -g $RG -l $LOC --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --allow-blob-public-access false
az storage blob service-properties update --account-name $SA --static-website \
  --index-document index.html --auth-mode login

az functionapp create -g $RG -n $FA --storage-account $SA \
  --flexconsumption-location $LOC --runtime python --runtime-version 3.11
az functionapp identity assign -g $RG -n $FA
PRINCIPAL=$(az functionapp identity show -g $RG -n $FA --query principalId -o tsv)
az role assignment create --assignee $PRINCIPAL --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n $SA -g $RG --query id -o tsv)

az functionapp config appsettings set -g $RG -n $FA --settings \
  STORAGE_ACCOUNT_URL=https://$SA.blob.core.windows.net WEB_CONTAINER='$web' \
  SCAN_SCHEDULE="0 30 5 * * 1" CHECK_PERMISSIONS=false

cd function_app && ./package.sh && func azure functionapp publish $FA
# first run, rather than waiting for Monday:
curl -X POST "https://$FA.azurewebsites.net/api/scan?code=<function key>"
az storage account show -n $SA -g $RG --query primaryEndpoints.web -o tsv   # the site URL
```

To switch on the permission check, set `CHECK_PERMISSIONS=true` and give the Function's managed identity `Application.Read.All` on Microsoft Graph:

```powershell
Connect-MgGraph -Scopes AppRoleAssignment.ReadWrite.All, Application.Read.All
$mi    = Get-MgServicePrincipal -Filter "displayName eq '<function app name>'"
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$role  = $graph.AppRoles | Where-Object Value -eq 'Application.Read.All'
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id -PrincipalId $mi.Id `
  -ResourceId $graph.Id -AppRoleId $role.Id
```

The static website endpoint is public. That's fine for this reference data. If you want it behind Entra sign-in, host `dist/` on Azure Static Web Apps or App Service with authentication instead.

## Deploy option B: GitHub Actions and GitHub Pages

`.github/workflows/scan.yml` runs the tests, scans, commits the refreshed data and publishes `dist/` to Pages every Monday, and whenever `curated.json` or the template changes. It's the cheapest option and gives you scan history in Git for free.

## Adding or editing content

Edit `data/curated.json` and nothing else.

- **Sub-service:** each workload has an ordered `subservices` list of `{"id": "...", "label": "..."}`. Ids only need to be unique within their workload.
- **Node:** `id`, `label`, `workload`, `subservice` (one of that workload's sub-service ids; required), `entityType` (fully qualified, for example `microsoft.graph.driveItem`), `path`, `summary`, `permissions.delegated` / `.application`, `licence`, `limits[]`, `mapping[]`, `docs`. Optional: `phase: 2`, `kind: "gap"` for things outside Graph, or `kind: "operation"` with `action` for actions such as `runHuntingQuery`.
- **Link:** `s`, `t`, `kind` = `nav` (give `nav`, the navigation property name), `ref` (give `label`, for example `appId`) or `action` (give `action`). Use `via` to show a longer path such as `planner/plans`.
- Run `python -m unittest discover tests`. The integrity test catches broken IDs, and `build_page.py` fails if a node has no sub-service, uses one from another workload, or a sub-service is left empty. To build before a new node is filed, use `--allow-unsorted`: the node shows under "Unsorted" and the scan summary lists it until someone sets its `subservice`.

## Known limitations

- The scanner verifies structure (types, relationships, actions), not behaviour. Throttling figures, licensing and "watch for" notes are curated by hand and checked against Microsoft Learn on 14 Nov 2026.
- Discovery only finds links whose target type exactly matches a node on the map. Relationships typed to a base type (such as `memberOf` → `directoryObject`) still need curating.
- The first scan sets the baseline. Change tracking starts from the second scan.

## Roadmap

- Phase 2: a full Purview deep dive (labels, DLP alerts, IRM, eDiscovery, audit, records, DSPM for AI), with the "not in Graph" PowerShell map.
- Sample requests per node, with an "Open in Graph Explorer" link.
- Links to Merill Fernando's Graph Permissions Explorer for each permission.
- Optional overlay of a tenant's own app permissions (opt-in, private hosting only).
