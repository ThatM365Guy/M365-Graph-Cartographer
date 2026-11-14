# CLAUDE.md: M365 Graph Cartographer (MGC)

Context for Claude Code. Read this before changing anything.

## What this is

M365 Graph Cartographer (MGC) is an interactive spider-diagram map of Microsoft Graph for Microsoft 365 practitioners (data security architects, admins), not developers. Graph sits in the middle, workloads are on an inner ring, and resources are on an outer ring. Chords show the relationships between resources. Hover shows a short card (endpoint, least-privileged permissions, main limitation); click opens full notes in a side panel.

The owner is a Microsoft Purview / data security architect. The tool is meant to be public community content as well as a client-facing reference. Write in UK English with plain, direct sentences.

A published copy of v0.1.0 exists as a Claude artifact. The source of truth is now this repo.

## Why we built it rather than reusing something

Existing tools we reviewed on 14 Nov 2026:
- **Graph Atlas MCP** (darrenjrobinson, MIT): a D3 force graph of entity types, permissions and roles, but it only runs inside an MCP host with MCP Apps support. It focuses on Entra and identity schema change tracking and has no documented hover notes.
- **Graph Permissions Explorer** (Merill Fernando): maps permissions to APIs, in tables. Good data source.
- **Graph X-Ray** (Merill): a browser extension that turns admin portal clicks into Graph calls. Not a map.
- **Graph Explorer**: a query tool with no relationship map.
- **Generic OData CSDL visualisers**: the full Graph schema is thousands of types, which is unreadable.

Our angle: a single shareable page, curated rather than a raw schema dump, with practitioner notes (licensing, limitations, gaps outside Graph), kept honest by a scheduled schema scan.

## Architecture

```
data/curated.json   hand-written content, the ONLY file people edit
scanner/scan.py     stdlib-only: v1.0 + beta $metadata -> data/graph-map.json + data/changelog.json
scanner/build_page.py   web/template.html + graph-map.json -> dist/index.html (data embedded)
function_app/       Azure Function (Python v2 model): weekly timer + POST /api/scan -> $web static site
.github/workflows/scan.yml   alternative: weekly Actions run -> commit data + GitHub Pages
tests/              unittest + small CSDL fixtures (v1.xml, beta.xml, v1_later.xml)
```

Rules to keep:
1. **Curated and generated data stay separate.** The scanner never writes `curated.json`.
2. **Standard library only** in `scanner/`, so it runs identically locally, in Actions and in Functions. The Function wrapper alone may use `azure-*` packages.
3. **The core scan is anonymous** (`$metadata` is public). The permission check is optional and needs a token with `Application.Read.All`.
4. **One self-contained page.** No runtime fetches, so it works as a static site, a file, or an artifact (whose CSP blocks external fetches).
5. **The page holds no tenant data**, so public hosting is fine.

## Data model (curated.json)

- `workloads[]`: `id`, `label`, `short` (pill text), `colour`, `summary`, `limits[]`, `docs`, optional `phase: 2`.
- `hub`: the Graph centre node.
- `nodes[]`: `id`, `label`, `workload`, `entityType` (fully qualified, for example `microsoft.graph.driveItem`), `path`, `summary`, `permissions.{delegated,application}`, `licence`, `limits[]`, `mapping[]`, `docs`. Optional: `phase: 2`, `kind: "gap"` (outside Graph), or `kind: "operation"` + `action` (for example `runHuntingQuery`).
- `edges[]`: `s`, `t`, `kind` = `nav` (+ `nav`), `ref` (+ `label`) or `action` (+ `action`). Optional `via` for display, for example `planner/plans`.

The scanner adds `node.scan` (status v1.0 / beta only / not found, plus props, navs, betaOnlyProps, betaOnlyNavs and baseTypes), `node.permCheck`, `edge.scan`, discovered edges (`kind: "discovered"`; navs in `DISCOVERY_SKIP_NAVS`, such as `createdByUser`, are never discovered), `recentChanges` and `state.permissionNames`. `build_page.py` strips `state` before embedding.

## Page (web/template.html)

- Vanilla JS, no libraries. The data is injected at the marker `/*__GRAPH_DATA__*/null`.
- **Semantic zoom:** `#vp` gets translate+scale; each node, pill and label sits in an inner `.sc` group counter-scaled by `--inv` = 1/k, so text and dots keep a fixed screen size. Strokes use `vector-effect: non-scaling-stroke`.
- Layout is radial: R1 = 205 (workload pills), R2 = 360 (resources). Sectors are proportional to node count, with a gap between them. Labels run radially and flip on the left half.
- Edge labels sit near the neighbour (u ≈ 0.78 along the quadratic curve), with greedy de-overlap.
- Design: the "Planning office" palette (stone #e7e4df, ink, brick #c8371e, white panels; night #171513), Schibsted Grotesk. Light and dark both work, including via `data-theme` on the root.
- Touch: a tap selects the node and docks the card at the bottom of the map. Mouse: hover shows the card, click pins the panel. The URL hash is the node id (for example `#user`).

## Commands

```bash
python -m unittest discover tests          # must pass before any commit
python scanner/scan.py                      # live scan (needs graph.microsoft.com)
python scanner/scan.py --no-scan            # re-merge curated edits, keep last scan results
python scanner/build_page.py                # writes dist/index.html
cd function_app; ./package.ps1              # Windows (package.sh on bash): copies scanner/data/web in before `func azure functionapp publish`
```

To check the page visually, open `dist/index.html` in a browser. Test at a desktop width (around 1440×900) and a phone width (around 390×844), in light and dark modes.

## Status (14 Nov 2026)

- 40 resources, 8 workloads, 57 curated links. All 9 tests pass.
- **First live scan done** (baseline 14 Nov 2026): 1,262 v1.0 and 2,624 beta entity types. Every typed node and every curated nav/action link resolves, and all 38 typed nodes are now in v1.0. The parser resolves all namespace aliases (`graph`, `self` and others).
- Curation decisions taken after the first scan:
  - Sensitivity label moved to the v1.0 type `microsoft.graph.sensitivityLabel` (`/security/dataSecurityAndGovernance/sensitivityLabels`). Permissions list v1.0 first (`SensitivityLabel.Read`), with the beta `InformationProtectionPolicy.*` ones as a note.
  - Drive item → Retention label is a `ref` labelled "retentionLabel (applied label)": `driveItem.retentionLabel` points to `itemRetentionLabel`, not the `security.retentionLabel` definition.
  - Curated from discovery: site/list/listItem → permission, event → calendar, group → calendar, user → site (`followedSites`).
- Scanner and page behaviour added: a curated `entityType` change is logged once as `retargeted` (not diffed as schema changes, no "Changed recently" badge); `createdByUser`/`lastModifiedByUser` are never discovered; parallel discovered links draw as one chord; discovered links are hidden by default and the status line counts curated links only.
- Still uncurated (beta only): team → user (`owners`), user → servicePrincipal (`appRoleAssignedResources`).
- The repo is on GitHub at `ThatM365Guy/M365-Graph-Cartographer` (private, `main`). Pages is not enabled and the workflow has not run yet.
- The permission check (`--permissions`) has never run.
- Known, not fixed: at phone width the outermost resource labels clip at the left and right edges (behaviour from v0.1).
- Facts checked against Microsoft Learn on 14 Nov 2026:
  - Advanced hunting: 30 days of data, 100,000 rows, 50 MB results, at least 45 calls per minute, 3-minute timeout.
  - driveItem simple upload: up to 250 MB. Upload session fragments: under 60 MiB, in multiples of 320 KiB. App-only calls cannot replace the content of a labelled file.
  - auditLogQuery: v1.0. Least privilege is AuditLogsQuery-Entra.Read.All, with workload-specific variants.
  - Sensitivity labels: v1.0 through the data security and governance API; the `/security/informationProtection` path is beta. v1.0 least privilege is SensitivityLabel.Read (delegated and application), higher SensitivityLabels.Read.All.
  - To Do supports the application permission Tasks.Read.All.
  - onlineMeeting app-only access needs a Teams application access policy, which takes up to 30 minutes to apply.

## Next steps (in order)

1. Go live: make the repo public, enable Pages (Source: GitHub Actions), then run the workflow by hand once (owner's preferred first host: free and public).
2. Run the permission check (`GRAPH_TOKEN` with `Application.Read.All`, `--permissions`) and fix any permission names it flags.
3. Phase 2: the Purview deep dive (labels and label actions, DLP alerts via alerts_v2, IRM, eDiscovery, audit, records management, DSPM for AI) and a fuller "not in Graph / PowerShell only" map.
4. Add sample requests per node with an "Open in Graph Explorer" link, and per-permission links to graphpermissions.merill.net.
5. Later, an opt-in private overlay of a tenant's own app permissions (never on the public build).

## Naming

The product name is **M365 Graph Cartographer**, and the short moniker is **MGC**. Use MGC for folder, resource and package names (for example `rg-mgc`, `func-mgc-*`, `mgc-scanner`). Earlier working names were "Microsoft 365 Graph map" and "MOGC / M365 Open Graph Crawler". We dropped MOGC because "Open Graph" clashes with Facebook's Open Graph protocol, and "crawler" suggests it crawls tenant data. "Compass" is taken by BrightenDigital's Compass M365, and "Graph Atlas" by Darren Robinson's tool.

## Conventions

- UK English in all user-facing text. Keep notes short and factual, and cite Microsoft Learn in `docs`.
- When a fact can drift (limits, licensing, versions), prefer letting the scanner verify it, or note the date it was checked.
- Never invent permission names. The `--permissions` scan flags unknown ones.
