# MGC: plan to map all of Microsoft Graph

Exported from the owner's Claude Doc "MGC: Claude Code brief to map all of Microsoft Graph" and saved here so later sessions can read it. This file is the source of truth for the work. Keep the progress and decisions sections up to date.

## Progress

- [x] Phase 0: git pull and tidy-up (28 Nov 2026)
- [x] Phase 1: make the ring cope with volume (branch `claude/phase1-ring-volume`, committed locally 28 Nov 2026; waiting for the owner's review and push)
- [x] Phase 2: generated tier, proved on Intune (branch `claude/phase2-generated-intune`, stacked on Phase 1, committed locally 28 Nov 2026; waiting for the owner's review and push)
- [x] Phase 3: every v1.0 area, then beta (branch `claude/phase3-all-areas`, stacked on Phase 2, committed locally 28 Nov 2026; waiting for the owner's review and push)
- [x] Phase 4: curated depth for security (branch `claude/phase4-security-depth`, cut from `main` after Phases 1-3 merged, committed locally 28 Nov 2026; scenario proposals waiting for the owner)
- [ ] Phase 5: extras

## Decisions and findings

- 28 Nov 2026, Phase 0: local `main` fast-forwarded from `fceca84` to `f0f3a58` (Scan 2026-11-23). Worktree `expanding-ring-redesign-b0cccb` removed and its merged branch deleted; its empty folder stayed behind, locked by another process. The stray folder `fix-pointer-freeze-0370c6` held only a `.claude/launch.json` for a worktree that no longer exists. Coverage figures after the pull match the brief exactly. `.claude/worktrees/` was only ignored through `.git/info/exclude`, so `.claude/` was added to `.gitignore` in Phase 1.
- 28 Nov 2026: owner said go for Phase 1.
- 28 Nov 2026, Phase 1 (Claude's choices, open to the owner's review):
  - The six new services are checked against v1.0 `$metadata` (scan of 23 Nov 2026 plus a fresh download on 28 Nov: 1,264 entity types). Each root exists: `/policies` (policyRoot), `/communications` (cloudCommunications), `/solutions` (solutionsRoot), `/education` (educationRoot), `/admin` (admin), `/deviceManagement` and `/deviceAppManagement`. Sub-service names follow those roots' navigation properties.
  - They are marked `planned: true` and have no nodes yet. The build allows empty sub-services only for planned services; the page draws them hollow and dashed ("Not mapped yet").
  - Families: Policies is identity; Communications, Solutions and Education are collaboration; Admin & service health and Devices (Intune) are security and compliance. No new family was added.
  - Learn's `solutionsRoot` page describes only cross-tenant migration, but v1.0 `$metadata` also has `bookingBusinesses`, `bookingCurrencies`, `backupRestore` and `virtualEvents` under `/solutions`. The map follows `$metadata`. Learn's major-services page still calls the Backup Storage API preview.
  - The `/identity` area (58 v1.0 types: Conditional Access root, External ID user flows, identity providers, custom authentication extensions) has no service of its own yet. Proposed: Conditional Access under Policies, the rest as an "External ID & sign-up" sub-service under Identity & directory. Decide in Phase 3.
  - Existing nodes that may move into the new services (not moved; owner to decide): Conditional Access policy (Identity › Access & risk → Policies › Conditional Access), online meeting (Teams › Meetings → Communications › Online meetings), message trace (Outlook › Exchange admin → Admin › Exchange, SharePoint & Teams admin), subscribed SKUs (Identity › Directory → Admin).
  - Ring cap: 8 bubbles per open sub-service (7 APIs plus "+n more" when there are more than 8). Service bubbles stop growing at 14 APIs so 16 services fit on the first ring.
  - Coverage: "mapped" = on the map (either tier), "curated" = hand-written entries. Both are 137 of 1,264 until the generated tier lands.
- 28 Nov 2026: owner said go for Phase 2. Phase 1 was pushed but not merged, so Phase 2 is cut from `claude/phase1-ring-volume`, not from `main`.
- 28 Nov 2026, Phase 2 (Claude's choices, open to the owner's review):
  - `permissions/new/permissions.json` exists and has the expected shape: `{"$schema", "permissions": {name: {"authorizationType", "schemes", "pathSets": [{"schemeKeys", "methods", "paths": {lowercase path: "least=<schemes>" | "" | "AlsoRequires=..."}}], "ownerInfo"}}}`, 975 permissions. The scanner checks this shape on every read and refuses a file that differs.
  - The catalogue often marks both a Read and a ReadWrite permission as least privileged for the same GET (106 of 129 Intune entries). The page lists every name marked least, in name order, under "generated, not checked", and does not choose between them.
  - The pin is the catalogue repository's HEAD commit, read from git's public refs endpoint, because the REST API's anonymous limit (60 calls an hour) ran out during this phase. The Learn index still needs two REST calls; `GITHUB_TOKEN` (if the workflow passes it) or `--docs-index` avoids the limit. Passing `GITHUB_TOKEN` in `.github/workflows/scan.yml` is a workflow change, so it is left for the owner.
  - Generated entries are built for every v1.0 type and saved in `data/generated.json`; only the areas in `data/placement.json` reach the map. Phase 3 can then extend placement with `--no-scan`.
  - Variants: a type that no root reaches folds into its nearest ancestor that one does (80 Intune variants, for example 26 device configuration platforms and 26 mobile app types). Labels say "(n variants)" rather than "platforms", because mobile app variants are app kinds, not platforms.
  - Learn links only when exactly one resource page fits the type name; 6 of 129 Intune entries have none (deviceManagement, deviceAppManagement, deviceCategory, deviceCompliancePolicyState, deviceConfigurationState, mobileAppContentScript).
  - 15 of 129 Intune entries have no GET entry in the catalogue (mostly nested paths, Cloud PC assignments, `/deviceManagement/virtualEndpoint`). Left blank.
- 28 Nov 2026: owner said go for Phase 3. Phase 2 was pushed but not merged, so Phase 3 is cut from `claude/phase2-generated-intune`.
- 28 Nov 2026, Phase 3 (Claude's choices, open to the owner's review):
  - Result: all 1,264 v1.0 types and all 1,369 beta-only types are placed. `placement.json` now lists `"areas": ["*"]`, so any new Graph area that no rule places fails the build.
  - Unrooted types: area assignment and paths now follow bound operation return types (15 types, for example `aiInteraction` and `exchangeMessageTraceDetail`), then plain relationships, then (areas only) an abstract base takes its derived types' area. Navs typed as `entity` are ignored, because they "reach" everything. 14 v1.0 types still have no area and are placed by `type` rules. `entity` itself is covered by the Graph hub (`hub.covers`), so curated counts 138 rather than 137.
  - 16 new sub-services, all inside existing services (still 16 services): Identity › External ID & guests, Tenant & organisation; Outlook › Places (rooms & desks); Files › OneNote, SharePoint Embedded & storage; Teams › Shifts & schedules, Teams apps & admin; Security › Threat intelligence, Attack simulation & training, Defender for Identity, Global Secure Access; Solutions › Viva learning & engagement, Universal Print, Business Central financials; Admin › Change notifications & extensions; AI › Copilot connectors & search. Names checked: "Microsoft 365 Copilot connectors (formerly Microsoft Graph connectors)", "Attack simulation and training" (Defender for Office 365), Global Secure Access and Business Central appear under those names on Learn.
  - Judgement calls to review: per-user authentication methods (`/users/{id}/authentication`) sit with Policies › Authentication; `/admin/exchange` and the beta message trace roots sit with Outlook › Exchange admin (next to the curated message trace node); Universal Print and Viva sit under Solutions; Entra access drift and tenant governance metrics sit under Identity › Tenant & organisation; Entra Permissions Management types (AWS, GCP, Azure permission definitions, beta) sit under Identity › Access & risk.
  - The six Phase 1 services are no longer `planned`: every sub-service now holds at least one API.
  - Ring: sub-service bubbles stop growing at 14 APIs, like services; six long sub-service names got a `short` ring name.
  - Beta-only generated entries are hidden until Filter › Beta-only APIs (generated) is on. No Learn link for them (the index lists v1.0 pages only).
  - The page is now 2.1 MB (generated entries about 1.6 MB). GitHub Pages serves it compressed. If it needs to shrink, the property lists of generated entries are the first candidate.
  - Nine catalogue permission names are not in the stored permission list (fetched 16 Nov), for example `Zone.Read.All`; the page flags them. A `--permissions` run would refresh the list.
- 28 Nov 2026: owner merged PRs #5, #6 and #7 into `main` (live, deploy run green). Owner pulled locally; Phase 4 is cut from `main`.
- 28 Nov 2026, Phase 4 (curated depth for security):
  - 12 curated nodes, every permission, licence and limit checked on Microsoft Learn on 28 Nov 2026, every path, relationship and Learn page checked against $metadata and the docs index: authentication method, user registration details (Policies › Authentication); risk detection, risky service principal (Identity › Access & risk); cross-tenant access policy (Policies › Cross-tenant access); managed device, device compliance policy (Devices); attack simulation, Secure Score control profile (Security); service health issue, Message centre post (Admin › Service health); provisioning log (Reports › Sign-in & audit logs). 12 curated links (one, user → managed device, was found by the scanner and curated).
  - Left blank because Learn doesn't state it on the API pages: licence for authentication methods, cross-tenant access policy, Secure Score control profiles, service health and Message centre.
  - Facts recorded as Learn states them, though they look odd: List riskDetections says Entra ID P1 or P2 (the existing risky user node says P2 for full data).
  - Curated now covers 153 of 1,264 v1.0 types (12%).
  - Known cosmetic issue, not fixed: a "↳ API" link tag can sit over service labels on the left of the ring (seen with the compliance policy selected). MGC.check doesn't cover link tags.

#### Phase 4 scenario proposals (not written into curated.json; waiting for the owner)

Each step names the node and what to do; the call, permission and catch default to the node's own notes. Filters marked "to confirm" must be checked on Learn before the scenario is written.

1. **Compromised workload identity triage** (Classic): risky service principal (list atRisk, Workload ID Premium) → service principal (owners, credentials) → app role assignment (what it can do) → sign-in (service principal sign-ins, filter to confirm) → directory audit (recent changes to the app).
2. **Risky sign-in investigation** (Classic): risk detection (riskEventType, IP, location) → risky user (state, history) → sign-in (the request behind the detection, join to confirm) → authentication method (was a new method registered?) → directory audit (method and role changes).
3. **Device compliance gap behind Conditional Access** (Classic): device compliance policy (which policies and platforms) → managed device (complianceState, last sync) → device (join by azureADDeviceId = deviceId) → Conditional Access policy (which policies require a compliant device).
4. **Phishing simulation follow-up** (Classic): attack simulation (campaigns and results) → repeat offenders report (/reports/security/getAttackSimulationRepeatOffenders) → user → user registration details (are repeat offenders MFA capable?) → risky user.
5. **Provisioning failure review** (Classic): provisioning log (failures, filter on provisioningStatusInfo/status to confirm) → service principal (the provisioning app) → user (the target identity) → directory audit.
6. **Weekly posture and change review** (Classic): Secure Score → Secure Score control profile (open improvement actions) → Message centre post (action-required changes) → service health issue (open incidents).

Overlap with Phase 6: Phase 6 scenario 2 (phishing-resistant MFA migration) and scenario 6 (Conditional Access coverage) will also use user registration details, authentication method and cross-tenant access policy, so they are not proposed again here.

---

## Brief

Brief for Claude Code, to run in `C:\Users\tomo9\Desktop\Tech-Stuff\Claude\MGC`. It takes M365 Graph Cartographer from 137 to all 1,264 v1.0 types, starting with a git pull and tidy-up. The phases are under Tasks for Claude Code.

### Where it stands

MGC is live with the expanding ring, but it maps 137 of 1,264 v1.0 resource types: about 11% of Microsoft Graph.

- **Live since 16 Nov 2026.** The expanding ring, sub-services, the one-row header and the scenarios went out in PR #4. The weekly scan ran on 23 Nov and worked: it picked up new Agent identity properties and two print types promoted from beta to v1.0.
- **Coverage.** The 73 curated resources cover 137 v1.0 types and touch 28 of 132 Graph areas. Only 5 of 1,368 beta-only types are on the map. Purview stands at 41 of 62, and identity governance at 49 of 84.
- **Housekeeping.** The local MGC folder is still at the 16 Nov morning version. The redesign is on GitHub but was never pulled locally, and the Claude Code worktree is parked on an old branch. Run `git pull` on main and `git worktree remove` before the next build.

Biggest gaps, from `data/coverage.json` (scan of 23 Nov 2026):

| Graph area | v1.0 types | On the map |
|---|---:|---:|
| deviceManagement (Intune devices) | 134 | 0 |
| security | 100 | 36 |
| users | 87 | 13 |
| sites | 76 | 6 |
| deviceAppManagement (Intune apps) | 75 | 0 |
| solutions (Bookings, Backup and others) | 59 | 0 |
| identity | 58 | 0 |
| policies | 57 | 1 |

A further 89 v1.0 types are unrooted: no path reaches them from a root, so the scanner can't place them.

### Why mapping everything needs a different approach

Hand-writing an entry for every one of the 2,632 types isn't realistic, and a ring with that many bubbles would be unreadable.

Each entry so far has a hand-written summary, permissions, limits and licensing, all checked against Microsoft Learn. Many types also aren't separate APIs. In the two Intune areas, 74 of the 209 v1.0 types are Android, iOS or Windows versions of the same policy. Others are base types or settings objects.

### Design: two tiers

Every v1.0 type gets a generated entry from the schema, and curated entries add depth on top.

**Generated tier:** everything, built by the scanner.

- Every addressable resource gets an entry from `$metadata`: path or paths from a root, v1.0 or beta, properties, navigation properties, bound actions and functions.
- Platform variants are folded into their base type as one entry, for example "Compliance policy (13 platforms)". The variant names stay in its detail.
- A rules table in a new file, `data/placement.json`, puts each entry in a service and sub-service, by root path first and then by namespace or area. The build fails on any v1.0 type that no rule places.
- Permissions come from Microsoft's path-to-permission catalogue: `permissions/new/permissions.json` in `microsoftgraph/microsoft-graph-devx-content`, refreshed in a weekly sync. Mark them "generated, not checked", because Microsoft's own reviews of that file flag least-privilege errors.
- Each entry links to its Microsoft Learn page where one can be found. No summaries, limits or licensing are made up for generated entries.

**Curated tier:** what `curated.json` holds now. Hand-written summaries, limits, licensing and scenarios. A curated entry overrides the generated entry for the same type. The page shows a badge saying which tier an entry comes from.

Completeness becomes a build rule, like the sub-service rule: the build fails if any v1.0 type is unplaced. That keeps the map complete as Graph grows each week. Beta-only types are placed too, but stay hidden behind a Filter switch that is off by default.

### Tasks for Claude Code

Work through the phases in order. Stop and report at the end of each phase, and wait for the owner's go-ahead before starting the next.

#### Ground rules

- Read CLAUDE.md first and follow it.
- Work on a new branch per phase, cut from an up-to-date main. A push to main deploys the live site, and mgc-bot also commits to main after each scan.
- Stop and ask before any push, PR, workflow change, GitHub setting or Azure change. Commit locally, then give the owner the commands to push.
- Never invent permission names, API paths, limits or licensing. Leave a gap blank and list it in the report.
- No tenant data in the public build.

#### Phase 0: git pull and tidy-up

The local folder is behind GitHub. Local main is at `fceca84`, from the morning of 16 Nov. `origin/main` is at `f0f3a58` (Scan 2026-11-23) and includes PR #4. The worktree `.claude/worktrees/expanding-ring-redesign-b0cccb` is checked out on an old branch.

```
git status
git switch main
git fetch --prune
git pull --ff-only
git worktree list
git worktree remove .claude/worktrees/expanding-ring-redesign-b0cccb
git worktree prune
git branch --merged main
git branch -d claude/expanding-ring-redesign-b0cccb
```

- Stop if `git status` shows uncommitted changes, and report them. Don't stash or discard anything.
- `git branch -d` only deletes merged branches. If it refuses, report it, and don't use `-D` without asking.
- The folder `.claude/worktrees/fix-pointer-freeze-0370c6` isn't a registered worktree. Check that it holds nothing missing from main, then ask before deleting it.
- Check that `.claude/worktrees/` is in `.gitignore`.
- Check the result: main equals origin/main, `git worktree list` shows one entry, and the tests pass.

#### Phase 1: make the ring cope with volume

- Cap each open sub-service on the ring at about 8 bubbles: curated entries first, then the most-linked generated ones. A final "+n more" bubble opens a searchable, sortable list in the side panel, and picking a row selects that entry.
- Add services for the new areas. Proposed: Devices (Intune), Admin & service health, Policies, Communications, Solutions (Bookings, Backup, Virtual events) and Education. Put each in a family and give it a shade, and propose sub-services for each in the report.
- Keep every label check passing with 16 services. Re-run `MGC.check()` and the Playwright checks at 1440×900, 1280×800 and 1280×720.
- Change Coverage so it shows mapped and curated as separate figures.

#### Phase 2: generated tier, proved on Intune

- Read `permissions.json` from `microsoftgraph/microsoft-graph-devx-content` in the scanner. Pin the commit it used in `meta.scan`. If the file's shape doesn't match what's expected, stop and report.
- Build generated entries for deviceManagement and deviceAppManagement (209 v1.0 types, none on the map today), with platform variants folded together.
- Add `data/placement.json` and the build rule, starting with the two Intune areas.
- Add tests for the variant folding, the placement rules and the curated-over-generated override.

#### Phase 3: every v1.0 area, then beta

- Extend `placement.json` to every v1.0 area, until the build rule passes for all 1,264 types.
- Follow function return types (for example `getAllEnterpriseInteractions` to `aiInteraction`), so the 89 unrooted types get placed.
- Add beta-only types behind a Filter switch that is off by default.

#### Phase 4: curated depth for security

Add curated entries, checked against Microsoft Learn, in this order:

1. authentication methods and registration details
2. risk detections and risky service principals
3. cross-tenant access policy
4. Intune managed devices and compliance policies
5. attack simulation and Secure Score control profiles
6. service health and Message centre
7. provisioning logs

Propose new scenarios that use them.

#### Phase 5: extras

- An "Open in Graph Explorer" link on each entry.
- A link from each permission to graphpermissions.merill.net.

#### Report at the end of each phase

- What changed, file by file.
- Anything left blank or uncertain.
- New coverage figures.
- The commands to view the build locally.
- The git commands for the owner to push the branch and open a PR.

### Sources

- microsoft-graph-devx-content: Weekly Permissions sync 2026-10-21 (PR #1666)
- microsoft-graph-devx-content: Weekly Permissions sync 2026-10-20 (PR #1665)
- microsoft-graph-devx-content: commit b9a67f1, `permissions/new/permissions.json`
- MGC repository: CLAUDE.md, `data/coverage.json` and `data/changelog.json` at `f0f3a58` (Scan 2026-11-23).

---

## Added by the owner on 28 Nov 2026: Phases 6 and 7

Start these only when the owner says go. The same ground rules apply: stop and ask before anything that touches GitHub or Azure, and never invent permission names, API paths or cmdlet names.

- [ ] Phase 6: nine new scenarios
- [ ] Phase 7: script examples for every scenario

#### Phase 6: nine new scenarios

Add these scenarios, chosen from the owner's ranked list of 50 Graph use cases. Before writing anything into `curated.json`, propose the steps for each one and wait for the owner's approval. Use the same shape as the existing 15: node, what to do, the call, the permission, the catch. They need the curated nodes from Phase 4.

1. Least-privilege review of agents' and apps' Graph permissions
2. Phishing-resistant MFA migration tracking (passkeys)
3. "Anyone" and organisation-wide sharing link audit
4. Workload identity hygiene: expiring secrets, unused and over-permissioned apps
5. Sensitivity label coverage as a Copilot readiness gate
6. Conditional Access coverage and gap analysis
7. EWS to Graph migration of mail-integrated apps
8. ROT clean-up: stale, duplicate and orphaned content. Suggested route:
   1. The SharePoint site usage report (last activity, storage used).
   2. Then site and drive.
   3. Then old files and version counts.
   4. Then each file's retention label, before anything is marked for deletion.
9. Licence clean-up, including Copilot seats. Suggested route:
   1. Subscribed SKUs (bought against used).
   2. Then licensed users with their sign-in activity.
   3. Then disabled accounts that still hold licences.
   4. Then group-based licence assignments.
   5. Then Copilot usage.

Add a fourth scenario group, "Cost and hygiene", for 8 and 9.

#### Phase 7: script examples for every scenario

Every scenario gets a script that people can run themselves: the 15 that exist and the 9 from Phase 6. Read-only scripts come first. Scripts that change things are out of scope for this phase.

1. Format.
   - Each step keeps its HTTP call and gains its Microsoft Graph PowerShell equivalent (Microsoft.Graph SDK v2, PowerShell 7).
   - Each scenario also gets one full script in `scripts/scenarios/<scenario-id>.ps1`. It runs the scenario's read-only steps from start to finish and writes the results to a local CSV file.
2. Read-only rules.
   - `Connect-MgGraph` asks only for the least-privileged delegated `.Read` scopes the steps need.
   - Only `Get-Mg*` cmdlets and `Invoke-MgGraphRequest -Method GET` are allowed.
   - A few read-only calls use POST, such as `runHuntingQuery` and creating an `auditLogQuery`. Put each one on an allow list and label it "read-only, uses POST".
   - Nothing is sent anywhere except Microsoft Graph, and no tenant data goes into the repository.
3. Script header. Each script starts with:
   - its purpose
   - the scopes it needs
   - the Entra roles it needs
   - the licence it needs
   - its parameters, with safe defaults (for example `-DaysInactive 90`)
   - what it doesn't do
   - a link to its scenario on the live site
4. Checks in the tests.
   - Every cmdlet must exist in the Microsoft.Graph modules and match its step's call. Use `Find-MgGraphCommand` for this.
   - PSScriptAnalyzer must report no errors.
   - A guard fails the build on any `New-`, `Set-`, `Update-`, `Remove-` or `Add-` cmdlet, or on any non-GET request that isn't on the allow list.
5. Page.
   - The scenario walk gets an HTTP / PowerShell switch on each step, with a Copy button.
   - Each scenario gets a "Download script" link.
   - A short note says the scripts are examples to read before running, and are provided as-is.
6. Testing.
   - A script is marked "Tested" only after the owner has run it in their own dev tenant. Record the date.
   - Don't run scripts against any tenant yourself. Give the owner the exact commands to run.
7. Later, not now. A separate remediation tier of write scripts, with `-WhatIf` on by default and a clear warning.
