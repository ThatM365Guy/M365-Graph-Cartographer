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
scanner/scan.py     stdlib-only: v1.0 + beta $metadata -> data/graph-map.json + data/changelog.json + data/coverage.json
scanner/build_page.py   web/template.html + graph-map.json -> dist/index.html (data embedded)
function_app/       Azure Function (Python v2 model): weekly timer + POST /api/scan -> $web static site
.github/workflows/scan.yml   live host: weekly Actions run -> commit data + GitHub Pages
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
- `scenarios[]`: `id` (ASCII letters, digits and hyphens; it goes in the hash as `#scenario-<id>`), `label`, `group` (`Classic` or `AI`), `summary` (why it matters, one sentence), `licence`, `steps[]`. A step is `{node, do}` plus optional `call`, `permission`, `licence`, `note` (the gotcha); each defaults to the node's own `path`, permissions, `licence` and first limit. `or: true` makes a step an alternative to the one before it (same number, for example "Drive item / Message"). A test fails if a scenario references a missing node, has no steps or has a bad id.
- `edges[]`: `s`, `t`, `kind` = `nav` (+ `nav`), `ref` (+ `label`, optional `desc` replacing "reference by ID" in the panel, for example "matched by label name, not ID") or `action` (+ `action`). Optional `via` for display, for example `planner/plans`.

The scanner adds `node.scan` (status v1.0 / beta only / not found, plus props, navs, betaOnlyProps, betaOnlyNavs and baseTypes), `node.permCheck`, `edge.scan`, discovered edges (`kind: "discovered"`; navs in `DISCOVERY_SKIP_NAVS`, such as `createdByUser`, are never discovered), `recentChanges` and `state.permissionNames`. `build_page.py` strips `state` before embedding.

Coverage (`data/coverage.json`, never embedded): `parse_csdl` also reads EntityContainer EntitySets/Singletons (`Schema.roots`) and `ContainsTarget` navs. `assign_areas` puts each entity type in the area of the nearest top-level root that reaches it through containment (derived types included), with ties broken by `AREA_PRIORITY`; broad hubs (`users`, `groups`, `me`) lose ties and `/directoryObjects` only gets what nothing else reaches. Unreached types fall back to `<sub-namespace> (namespace)`, then `unrooted` (mostly abstract bases and types only returned by functions, such as `aiInteraction`). The file holds per-area counts, the names of types not on the map, and a `types` index (fq -> area, status) that the next scan diffs for "New in Graph" entries (new v1.0 types, promotions from beta, new roots). `recentChanges` keeps at most `NEW_IN_GRAPH_RECENT` (5) of each kind plus a summary line; `changelog.json` (now up to 2,000 entries) keeps them all. `graph-map.json` gets `coverage` with counts only, and `--no-scan` recounts it from the previous `coverage.json`.

## Page (web/template.html)

- Vanilla JS, no libraries. The data is injected at the marker `/*__GRAPH_DATA__*/null`.
- **Semantic zoom:** `#vp` gets translate+scale; each node, pill and label sits in an inner `.sc` group counter-scaled by `--inv` = 1/k, so text and dots keep a fixed screen size. Strokes use `vector-effect: non-scaling-stroke`.
- Layout is radial: R1 = 205 (workload pills), R2 = 360 (resources). Sectors are proportional to node count, with a gap between them. Labels run radially and flip on the left half.
- Edge labels sit near the neighbour (u ≈ 0.78 along the quadratic curve), with greedy de-overlap.
- Design: the "Planning office" palette (stone #e7e4df, ink, brick #c8371e, white panels; night #171513), Schibsted Grotesk. Light and dark both work, including via `data-theme` on the root.
- **Scenarios:** the "Scenarios ▾" chip in the filter bar opens a menu grouped Classic / AI; the overview panel lists them too (for phones). Opening one adds `svg.scen` (dims everything off the route), numbered `.badge`s inside each route node's `.sc` group (on the inner side of the ring, staggered for neighbours), and bold `.routeln` curves between consecutive steps in `#routes`. The panel lists the steps; selecting a step centres on its node, and tapping a route node on the map flashes its step. A background tap keeps the scenario; selecting another node, Escape or "Clear scenario" leaves it.
- **Coverage:** the overview panel has a Coverage table (area, on map / v1.0, beta only) and the status line reads "N of 1,262 v1.0 types".
- Pointer input: only the primary mouse button (or touch/pen) starts a pan or select. `endGesture()` clears the gesture on lostpointercapture, contextmenu, the pointer leaving the window, window blur and the tab being hidden, and a mouse move with no buttons held ends a drag.
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

## Status (16 Nov 2026)

- `main`: 40 resources, 8 workloads. Hotfix on 16 Nov 2026 (commit "Fix stuck pan/hover after right-click or interrupted drag"): a right-click or a drag released outside the window left the pan stuck on and hover cards off. Deployed green.
- `feature/scenarios` (not merged; awaiting the owner's review): 52 resources, 9 workloads (new: AI & agents), 86 curated links, 12 scenarios, coverage report. 20 tests pass.
- First live scan baseline 14 Nov 2026: 1,262 v1.0 and 2,624 beta entity types (1,370 beta only). Every typed node and every curated nav/action link resolves; all 47 typed nodes on the branch are in v1.0.
- **Permission check first run 16 Nov 2026** (`--permissions`, az CLI token): 1,036 Graph permission names; every name on the map exists, and each sits on the right side (delegated or application). Rerun it whenever permissions are edited.
- Curation decisions taken after the first scan:
  - Sensitivity label moved to the v1.0 type `microsoft.graph.sensitivityLabel` (`/security/dataSecurityAndGovernance/sensitivityLabels`). Permissions list v1.0 first (`SensitivityLabel.Read`), with the beta `InformationProtectionPolicy.*` ones as a note.
  - Drive item → Retention label is a `ref` labelled "retentionLabel (applied label)", described as "matched by label name, not ID".
  - Curated from discovery: site/list/listItem → permission, event → calendar, group → calendar, user → site (`followedSites`), and on the branch user → servicePrincipal (`appRoleAssignedResources`, beta only), group → appRoleAssignment, agentIdentity → appRoleAssignment.
  - A curated `entityType` change is logged once as `retargeted`; `createdByUser`/`lastModifiedByUser` are never discovered; parallel discovered links draw as one chord; discovered links are hidden by default.
- Curated on 16 Nov 2026 at the owner's request: team → user (`owners`, beta only). No discovered links remain uncurated.
- **Live** at https://thatm365guy.github.io/M365-Graph-Cartographer/ from the public repo `ThatM365Guy/M365-Graph-Cartographer` (`main`), deployed by `.github/workflows/scan.yml` (actions checkout v7, setup-python v7, upload-pages-artifact v5, deploy-pages v5 on Node 24). Runs fully green since 14 Nov 2026.
- GitHub settings: Pages source is GitHub Actions with HTTPS enforced. The job runs in the `github-pages` environment, which only allows deploys from `main`, and the push trigger is limited to `main`. Actions are restricted to GitHub-owned actions; a third-party action needs that setting changed first. The default workflow token is read-only and the workflow asks for write itself. `main` has no branch protection, because mgc-bot pushes to it.
- Every push to `main` that touches `curated.json` or the template publishes straight to the live site, and mgc-bot then commits refreshed data. Pull before pushing, and use a branch for larger changes, merging to `main` when ready.
- Scans without a token (including the weekly Actions run and `--no-scan`) re-check permission names against `state.permissionNames`, the list stored by the last `--permissions` run, and keep `permCheck`. `meta.scan.permissionsCheckedAt` (shown in the page footer) is the date that list was fetched, so refresh it now and then with a local `--permissions` run.
- Known, not fixed: at phone width the outermost resource labels clip at the left and right edges (behaviour from v0.1).
- Facts checked against Microsoft Learn on 14 Nov 2026:
  - Advanced hunting: 30 days of data, 100,000 rows, 50 MB results, at least 45 calls per minute, 3-minute timeout.
  - driveItem simple upload: up to 250 MB. Upload session fragments: under 60 MiB, in multiples of 320 KiB. App-only calls cannot replace the content of a labelled file.
  - auditLogQuery: v1.0. Least privilege is AuditLogsQuery-Entra.Read.All, with workload-specific variants.
  - Sensitivity labels: v1.0 through the data security and governance API; the `/security/informationProtection` path is beta. v1.0 least privilege is SensitivityLabel.Read (delegated and application), higher SensitivityLabels.Read.All.
  - Site, list and list item permissions: all v1.0 (`/sites/{id}/permissions`, `/lists/{id}/permissions`, `/items/{id}/permissions`). Reading needs Sites.Read.All. Creating them only grants access to applications, never users.
  - To Do supports the application permission Tasks.Read.All.
  - onlineMeeting app-only access needs a Teams application access policy, which takes up to 30 minutes to apply.
- Facts checked against Microsoft Learn on 16 Nov 2026 (new nodes):
  - Conditional Access: Policy.Read.All. Policies for all users don't include agent users; agents are targeted explicitly (preview) and need Microsoft Agent 365 (in Microsoft 365 E7) plus P1 or E3.
  - Risky user: IdentityRiskyUser.Read.All; confirmCompromised/dismiss need IdentityRiskyUser.ReadWrite.All; full data needs P2.
  - OAuth grants: Directory.Read.All; the per-user list has no application permission and omits AllPrincipals grants.
  - App role assignments: Application.Read.All for appRoleAssignedTo; Learn lists AppRoleAssignment.ReadWrite.All as least delegated for the per-user list (we show Directory.Read.All and note this).
  - PIM eligibility: RoleEligibilitySchedule.Read.Directory; P2 or ID Governance.
  - subscribedSkus: LicenseAssignment.Read.All; licenseDetails lists no application permission.
  - Inbox rules: MailboxSettings.Read; only Inbox rules; mailbox forwarding, outbound spam policy, remote domains and transport rules are Exchange Online PowerShell only.
  - getAllEnterpriseInteractions: application only (AiEnterpriseInteraction.Read.All), Copilot licence, excludes Copilot Studio agents, createdDateTime filters need both bounds.
  - Purview APIs for AI apps (v1.0): ProtectionScopes.Compute.User, Content.Process.User, ContentActivity.Write; pay-as-you-go billing.
  - Agent identity / blueprint (v1.0): AgentIdentity.Read.All, AgentIdentityBlueprint.Read.All. Licensing is inconsistent across Learn pages, so the notes say "drifting". The sign-in `agent` property is beta only.
  - revokeSignInSessions: User.RevokeSessions.All. signInActivity: P1, AuditLog.Read.All + User.Read.All, up to 24 hours' lag.

## Next steps (in order)

1. Owner review of `feature/scenarios`, then merge to `main` (it deploys straight to the live site).
2. Tier 2 nodes, ordered by the coverage report: identity governance (access reviews, access packages, lifecycle workflows), authentication methods and registration details, risk detections and risky service principals, cross-tenant access policy, Intune (managed devices, compliance policies), attack simulation and Secure Score control profiles, threat intelligence, subject rights requests, service health and Message centre, provisioning logs.
3. Phase 2: the Purview deep dive (labels and label actions, DLP alerts via alerts_v2, IRM, eDiscovery, audit, records management, DSPM for AI) and a fuller "not in Graph / PowerShell only" map.
4. Sample requests per node with an "Open in Graph Explorer" link, and per-permission links to graphpermissions.merill.net.
5. Coverage: follow function return types (for example `getAllEnterpriseInteractions` -> `aiInteraction`) so fewer types land in `unrooted`.
6. Later, an opt-in private overlay of a tenant's own app permissions (never on the public build).

## Naming

The product name is **M365 Graph Cartographer**, and the short moniker is **MGC**. Workload ids are short lowercase words; the AI workload is `ai`, labelled "AI & agents", pill "AI", colour #d6247a (chosen for a colour distance of at least 27 ΔE from every other workload and the brick accent, and about 3.8:1 contrast on both the light and the dark background). Use MGC for folder, resource and package names (for example `rg-mgc`, `func-mgc-*`, `mgc-scanner`). Earlier working names were "Microsoft 365 Graph map" and "MOGC / M365 Open Graph Crawler". We dropped MOGC because "Open Graph" clashes with Facebook's Open Graph protocol, and "crawler" suggests it crawls tenant data. "Compass" is taken by BrightenDigital's Compass M365, and "Graph Atlas" by Darren Robinson's tool.

## Conventions

- UK English in all user-facing text. Keep notes short and factual, and cite Microsoft Learn in `docs`.
- When a fact can drift (limits, licensing, versions), prefer letting the scanner verify it, or note the date it was checked.
- Never invent permission names. The `--permissions` scan flags unknown ones.
