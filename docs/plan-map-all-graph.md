# MGC: plan to map all of Microsoft Graph

Exported from the owner's Claude Doc "MGC: Claude Code brief to map all of Microsoft Graph" and saved here so later sessions can read it. This file is the source of truth for the work. Keep the progress and decisions sections up to date.

## Progress

- [x] Phase 0: git pull and tidy-up (28 Nov 2026)
- [x] Phase 1: make the ring cope with volume (branch `claude/phase1-ring-volume`, committed locally 28 Nov 2026; waiting for the owner's review and push)
- [ ] Phase 2: generated tier, proved on Intune
- [ ] Phase 3: every v1.0 area, then beta
- [ ] Phase 4: curated depth for security
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
