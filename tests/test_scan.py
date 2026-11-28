"""Offline tests for the scanner, using small CSDL fixtures. Run: python -m unittest discover tests"""
import copy
import datetime as dt
import json
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "scanner"))

import scan  # noqa: E402
import build_page  # noqa: E402

FX = os.path.join(HERE, "fixtures")
D1 = dt.datetime(2026, 11, 14, tzinfo=dt.timezone.utc)
D2 = dt.datetime(2026, 11, 21, tzinfo=dt.timezone.utc)


# The fixtures model these nodes with fixed types, so the tests don't break when curated.json is re-pointed.
FIXTURE_TYPES = {"sensitivityLabel": "microsoft.graph.security.sensitivityLabel"}


def curated():
    with open(os.path.join(ROOT, "data", "curated.json"), encoding="utf-8") as f:
        cur = json.load(f)
    for n in cur["nodes"]:
        if n["id"] in FIXTURE_TYPES:
            n["entityType"] = FIXTURE_TYPES[n["id"]]
    return cur


def real_map(**kw):
    """The map as the real build makes it: curated content plus data/generated.json placed by data/placement.json."""
    with open(os.path.join(ROOT, "data", "generated.json"), encoding="utf-8") as f:
        gen = json.load(f)
    with open(os.path.join(ROOT, "data", "placement.json"), encoding="utf-8") as f:
        placement = json.load(f)
    return scan.build_map(kw.pop("cur", None) or curated(), None, scan=False, now=D1, prev_generated=gen,
                          placement=placement, **kw)


def scenario_problems(c):
    """Everything wrong with curated scenarios, as readable strings."""
    ids, seen, out = {n["id"] for n in c["nodes"]}, set(), []
    for sc in c.get("scenarios", []):
        sid = sc.get("id", "?")
        if not re.fullmatch(r"[A-Za-z0-9-]+", sid):
            out.append(f"{sid}: id must be ASCII letters, digits and hyphens (it goes in the URL hash)")
        if sid in seen:
            out.append(f"{sid}: duplicate id")
        seen.add(sid)
        if sc.get("group") not in {"Classic", "AI", "Purview", "Cost and hygiene"}:
            out.append(f"{sid}: group must be Classic, AI, Purview or Cost and hygiene")
        if not (sc.get("label") and sc.get("summary")):
            out.append(f"{sid}: needs a label and a summary")
        steps = sc.get("steps") or []
        if not steps:
            out.append(f"{sid}: no steps")
        elif steps[0].get("or"):
            out.append(f"{sid}: the first step can't be an alternative")
        scen_ids = {x.get("id") for x in c.get("scenarios", [])}
        for other in sc.get("seeAlso") or []:
            if other not in scen_ids or other == sid:
                out.append(f"{sid}: seeAlso {other} is not another scenario")
        for st in steps:
            if st.get("node") not in ids:
                out.append(f"{sid}: missing node {st.get('node')}")
            if not st.get("do"):
                out.append(f"{sid}: a step has no 'do'")
    return out


def legacy_problems(c):
    out = []
    for n in c["nodes"]:
        for l in n.get("legacy") or []:
            if not l.get("path"):
                out.append(f"{n['id']}: a legacy entry has no path")
            elif not (l.get("replacedBy") or l.get("note")):
                out.append(f"{n['id']}: {l['path']} needs replacedBy or a note")
    return out


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.v1 = scan.parse_csdl(os.path.join(FX, "v1.xml"))

    def test_alias_and_inheritance(self):
        eff = self.v1.effective("microsoft.graph.user")
        self.assertIn("id", eff["props"])                 # from graph.entity, two levels up
        self.assertIn("deletedDateTime", eff["props"])    # from directoryObject
        self.assertEqual(eff["navs"]["drive"], "microsoft.graph.drive")
        self.assertEqual(eff["navs"]["followedSites"], "microsoft.graph.site")  # Collection() stripped

    def test_sub_namespace_and_bound_actions(self):
        self.assertEqual(self.v1.effective("microsoft.graph.security.incident")["navs"]["alerts"],
                         "microsoft.graph.security.alert")
        self.assertTrue(self.v1.operation_bound("microsoft.graph.driveItem", "assignSensitivityLabel"))
        self.assertTrue(self.v1.operation_anywhere("runHuntingQuery"))
        self.assertFalse(self.v1.operation_bound("microsoft.graph.user", "assignSensitivityLabel"))


class ScanTests(unittest.TestCase):
    def run_scan(self, v1, beta, prev=None, now=D1):
        return scan.build_map(curated(), prev, os.path.join(FX, v1), os.path.join(FX, beta), now=now)

    def test_statuses_and_edges(self):
        gm, changes = self.run_scan("v1.xml", "beta.xml")
        nodes = {n["id"]: n for n in gm["nodes"]}
        self.assertEqual(nodes["user"]["scan"]["status"], "v1.0")
        self.assertEqual(nodes["sensitivityLabel"]["scan"]["status"], "beta only")
        self.assertEqual(nodes["chat"]["scan"]["status"], "not found")   # absent from the fixture
        self.assertEqual(nodes["hunting"]["scan"]["status"], "v1.0")
        self.assertIn("employeeLeaveDateTime", nodes["user"]["scan"]["betaOnlyProps"])
        self.assertNotIn("scan", nodes["spGap"])

        edges = {(e["s"], e["t"], e.get("nav") or e.get("action")): e for e in gm["edges"]}
        self.assertEqual(edges[("user", "drive", "drive")]["scan"], "v1.0")
        self.assertEqual(edges[("driveItem", "sensitivityLabel", "assignSensitivityLabel")]["scan"], "v1.0")
        self.assertEqual(edges[("user", "chat", "chats")]["scan"], "not found")
        self.assertEqual(edges[("application", "servicePrincipal", None)]["scan"], "n/a")
        self.assertEqual(edges[("user", "site", "followedSites")]["kind"], "nav")   # curated, so not discovered
        cur = curated()
        cur["edges"] = [e for e in cur["edges"] if (e["s"], e["t"]) != ("user", "site")]
        uncurated, _ = scan.build_map(cur, None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D1)
        disc = next(e for e in uncurated["edges"] if (e["s"], e["t"]) == ("user", "site"))
        self.assertEqual((disc["kind"], disc["nav"], disc["scan"]), ("discovered", "followedSites", "v1.0"))
        # baseItem.createdByUser reaches drive, driveItem and site, but audit-trail navs are skipped
        self.assertEqual(scan.parse_csdl(os.path.join(FX, "v1.xml")).effective("microsoft.graph.site")["navs"]["createdByUser"],
                         "microsoft.graph.user")
        self.assertFalse([e for e in gm["edges"] if e["kind"] == "discovered" and e["nav"] in scan.DISCOVERY_SKIP_NAVS])
        self.assertEqual([c["kind"] for c in changes], ["baseline", "graph-baseline"])

    def test_second_scan_reports_changes(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        second, changes = self.run_scan("v1_later.xml", "beta.xml", prev=first, now=D2)
        texts = " | ".join(c["text"] for c in changes)
        self.assertIn("Sensitivity label: moved from beta only to v1.0", texts)
        self.assertIn("User: new v1.0 property 'employeeLeaveDateTime'", texts)
        self.assertEqual(second["recentChanges"][0]["date"], "2026-11-21")
        promoted = [c["kind"] for c in changes if c["node"] == "sensitivityLabel"]
        self.assertEqual(promoted, ["status"])          # not one entry per property as well

    def test_changed_this_week_is_not_cut_by_the_recent_list(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        self.assertEqual(first["changedNodes"], {})                      # a baseline is not a change
        keep = scan.RECENT_KEEP
        scan.RECENT_KEEP = 1                                             # far fewer than the changes in this scan
        try:
            second, _ = self.run_scan("v1_later.xml", "beta.xml", prev=first, now=D2)
        finally:
            scan.RECENT_KEEP = keep
        self.assertEqual(len(second["recentChanges"]), 1)
        self.assertEqual(second["changedNodes"].get("user"), "2026-11-21")
        self.assertEqual(second["changedNodes"].get("sensitivityLabel"), "2026-11-21")
        kept, _ = scan.build_map(curated(), second, scan=False, now=D2 + dt.timedelta(days=30))
        self.assertEqual(kept["changedNodes"], second["changedNodes"])   # --no-scan keeps the list as it was
        later, _ = self.run_scan("v1_later.xml", "beta.xml", prev=second, now=D2 + dt.timedelta(days=8))
        self.assertEqual(later["changedNodes"], {})                      # older than a week, and nothing new
        old_map = {k: v for k, v in second.items() if k != "changedNodes"}
        seeded = scan.changed_this_week(old_map, [], None)               # a map from before changedNodes existed
        self.assertEqual(sorted(seeded), sorted(c["node"] for c in second["recentChanges"]
                                                if c["node"] and c["kind"] in scan.SCHEMA_CHANGE_KINDS))
        with open(os.path.join(ROOT, "web", "template.html"), encoding="utf-8") as f:
            self.assertIn("D.changedNodes", f.read())

    def test_retargeted_node_is_one_curation_entry_not_schema_changes(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        cur = curated()
        next(n for n in cur["nodes"] if n["id"] == "user")["entityType"] = "microsoft.graph.group"
        _, changes = scan.build_map(cur, first, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D2)
        user_changes = [c for c in changes if c["node"] == "user"]
        self.assertEqual([c["kind"] for c in user_changes], ["retargeted"])
        self.assertIn("from microsoft.graph.user to microsoft.graph.group", user_changes[0]["text"])

    def test_no_scan_after_a_retarget_hides_old_results_and_next_scan_logs_it_once(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        self.assertEqual(next(n for n in first["nodes"] if n["id"] == "user")["scan"]["of"], "microsoft.graph.user")
        cur = curated()
        next(n for n in cur["nodes"] if n["id"] == "user")["entityType"] = "microsoft.graph.group"
        mid, _ = scan.build_map(cur, first, scan=False, now=D2)
        self.assertNotIn("scan", next(n for n in mid["nodes"] if n["id"] == "user"))   # not the old type's schema
        self.assertEqual(mid["state"]["retargetedScans"]["user"]["of"], "microsoft.graph.user")
        again, _ = scan.build_map(cur, mid, scan=False, now=D2)                         # a second --no-scan keeps it
        self.assertEqual(again["state"]["retargetedScans"]["user"]["of"], "microsoft.graph.user")
        second, changes = scan.build_map(cur, again, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D2)
        self.assertEqual([c["kind"] for c in changes if c["node"] == "user"], ["retargeted"])
        self.assertNotIn("retargetedScans", second["state"])
        back, _ = scan.build_map(curated(), mid, scan=False, now=D2)                    # changed back before a scan
        self.assertEqual(next(n for n in back["nodes"] if n["id"] == "user")["scan"]["of"], "microsoft.graph.user")
        self.assertNotIn("retargetedScans", back["state"])

    def test_no_scan_keeps_previous_results_and_new_curated_text(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        cur = curated()
        cur["nodes"][0]["summary"] = "Edited by hand."
        gm, changes = scan.build_map(cur, first, scan=False, now=D2)
        user = next(n for n in gm["nodes"] if n["id"] == "user")
        self.assertEqual(user["summary"], "Edited by hand.")
        self.assertEqual(user["scan"]["status"], "v1.0")
        self.assertEqual(changes, [])

    def test_permission_check(self):
        perms = {"application": ["User.Read.All", "Sites.Selected"], "delegated": ["User.Read", "User.ReadBasic.All"]}
        res = scan.check_permissions(curated(), perms)
        self.assertEqual(res["user"]["unknown"], [])
        self.assertIn("Group.Read.All", res["group"]["unknown"])
        self.assertNotIn("v1.0", " ".join(sum((r["checked"] for r in res.values()), [])))


class PermissionCarryOverTests(unittest.TestCase):
    """Scans without a token re-check names against the list stored by the last token run."""

    def first_with_perms(self):
        perms = {"application": ["User.Read.All", "Sites.Selected"], "delegated": ["User.Read", "User.ReadBasic.All"]}
        orig = scan.fetch_permissions
        scan.fetch_permissions = lambda token: perms
        try:
            gm, _ = scan.build_map(curated(), None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"),
                                   token="t", now=D1)
        finally:
            scan.fetch_permissions = orig
        return gm

    def test_scan_without_token_keeps_checking(self):
        first = self.first_with_perms()
        self.assertEqual(first["state"]["permissionNamesAt"], "2026-11-14")
        cur = curated()
        user = next(n for n in cur["nodes"] if n["id"] == "user")
        user["permissions"] = {"delegated": "User.Read, User.Raed.All", "application": "User.Read.All"}
        gm, _ = scan.build_map(cur, first, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D2)
        nodes = {n["id"]: n for n in gm["nodes"]}
        self.assertEqual(nodes["user"]["permCheck"]["unknown"], ["User.Raed.All"])   # an edit is checked, not stale
        self.assertTrue(gm["meta"]["scan"]["permissionsChecked"])
        self.assertEqual(gm["meta"]["scan"]["permissionsCheckedAt"], "2026-11-14")
        self.assertEqual(gm["meta"]["scan"]["permissionCount"], 4)
        self.assertEqual(gm["state"]["permissionNames"], first["state"]["permissionNames"])

    def test_no_scan_rechecks_too(self):
        first = self.first_with_perms()
        gm, _ = scan.build_map(curated(), first, scan=False, now=D2)
        self.assertIn("Group.Read.All", next(n for n in gm["nodes"] if n["id"] == "group")["permCheck"]["unknown"])

    def test_never_checked_stays_unchecked(self):
        gm, _ = scan.build_map(curated(), None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D1)
        self.assertFalse(gm["meta"]["scan"]["permissionsChecked"])
        self.assertFalse(any("permCheck" in n for n in gm["nodes"]))


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.v1 = scan.parse_csdl(os.path.join(FX, "v1.xml"))
        self.beta = scan.parse_csdl(os.path.join(FX, "beta.xml"))

    def test_parse_roots_and_containment(self):
        self.assertEqual(self.v1.roots["users"], "microsoft.graph.user")
        self.assertEqual(self.v1.roots["security"], "microsoft.graph.security.security")
        self.assertEqual(self.v1.effective("microsoft.graph.user")["contained"], {"drive"})
        self.assertIn("items", self.v1.effective("microsoft.graph.drive")["contained"])

    def test_areas_follow_containment_from_the_nearest_root(self):
        area = scan.assign_areas(self.v1)
        self.assertEqual(area["microsoft.graph.user"], "users")          # /me is an alias of /users
        self.assertEqual(area["microsoft.graph.group"], "groups")
        self.assertEqual(area["microsoft.graph.drive"], "sites")         # equally close to users/groups/sites: priority
        self.assertEqual(area["microsoft.graph.itemRetentionLabel"], "sites")   # three levels down
        self.assertEqual(area["microsoft.graph.security.alert"], "security")
        self.assertEqual(area["microsoft.graph.baseItem"], "sites")      # abstract: takes its derived types' area

    def test_coverage_report_and_page_summary(self):
        gm_out = {}
        gm, _ = scan.build_map(curated(), None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"),
                               now=D1, coverage_out=gm_out)
        self.assertEqual(gm_out["v1Types"], len(self.v1.entities))
        self.assertEqual(gm_out["betaOnlyTypes"], 1)                    # sensitivityLabel
        sites = next(a for a in gm_out["areas"] if a["area"] == "sites")
        self.assertIn("driveItem", sites["onMapTypes"])
        self.assertIn("itemRetentionLabel", sites["onMapTypes"])     # via retentionLabel's covers[]
        self.assertIn("baseItem", sites["missing"])
        self.assertEqual(gm["coverage"]["onMap"], gm_out["onMap"])
        self.assertNotIn("missing", json.dumps(gm["coverage"]))         # the page gets counts only
        self.assertNotIn("types", gm["coverage"])

    def test_purview_lens(self):
        self.assertEqual(scan.purview_solution("microsoft.graph.security.retentionEvent"), "Records")
        self.assertEqual(scan.purview_solution("microsoft.graph.security.ediscoveryCustodian"), "eDiscovery")
        self.assertEqual(scan.purview_solution("microsoft.graph.security.dlp.baseAuditRecord"), "Audit")
        self.assertEqual(scan.purview_solution("microsoft.graph.subjectRightsRequest"), "Privacy")
        self.assertEqual(scan.purview_solution("microsoft.graph.userProtectionScopeContainer"), "Data security API")
        self.assertIsNone(scan.purview_solution("microsoft.graph.security.caseManagement.case"))   # Defender, not Purview
        self.assertIsNone(scan.purview_solution("microsoft.graph.user"))
        cov = {}
        cur = curated()
        gm, _ = scan.build_map(cur, None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D1, coverage_out=cov)
        sols = {r["solution"]: r for r in cov["purview"]["solutions"]}
        self.assertEqual(sols["Information protection"]["betaOnly"], 1)       # fixture security.sensitivityLabel
        self.assertEqual(gm["coverage"]["purview"]["betaOnly"], cov["purview"]["betaOnly"])
        self.assertNotIn("missing", json.dumps(gm["coverage"]["purview"]))
        cur["nodes"][0]["covers"] = ["microsoft.graph.baseItem"]   # covers[] counts as on the map
        again = {}
        scan.build_map(cur, None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D1, coverage_out=again)
        self.assertEqual(again["onMap"], cov["onMap"] + 1)

    def test_new_in_graph_entries_and_cap(self):
        first_cov = {}
        first, _ = scan.build_map(curated(), None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"),
                                  now=D1, coverage_out=first_cov)
        cov = {}
        _, changes = scan.build_map(curated(), first, os.path.join(FX, "v1_later.xml"), os.path.join(FX, "beta.xml"),
                                    now=D2, prev_coverage=first_cov, coverage_out=cov)
        texts = " | ".join(c["text"] for c in changes)
        self.assertIn("New in Graph v1.0: riskyUser", texts)
        self.assertIn("Promoted from beta to v1.0: security.sensitivityLabel", texts)
        self.assertIn("New top-level root in v1.0: /drives", texts)
        self.assertNotIn("graph-baseline", [c["kind"] for c in changes])
        many = [{"date": "2026-11-21", "node": None, "kind": "graph-new-type", "text": str(i)} for i in range(12)]
        capped = scan.cap_new_in_graph(many)
        self.assertEqual(len(capped), scan.NEW_IN_GRAPH_RECENT + 1)
        self.assertIn("7 more new v1.0 types", capped[-1]["text"])

    def test_no_scan_recounts_from_previous_coverage(self):
        cov = {}
        first, _ = scan.build_map(curated(), None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"),
                                  now=D1, coverage_out=cov)
        cur = curated()
        cur["nodes"] = [n for n in cur["nodes"] if n["id"] != "driveItem"]
        cur["edges"] = [e for e in cur["edges"] if "driveItem" not in (e["s"], e["t"])]
        again = {}
        gm, _ = scan.build_map(cur, first, scan=False, now=D2, prev_coverage=cov, coverage_out=again)
        self.assertEqual(gm["coverage"]["onMap"], cov["onMap"] - 1)
        self.assertIn("driveItem", next(a for a in again["areas"] if a["area"] == "sites")["missing"])


class CuratedIntegrity(unittest.TestCase):
    def test_edges_reference_real_nodes_and_workloads(self):
        c = curated()
        ids = {n["id"] for n in c["nodes"]}
        wl = {w["id"] for w in c["workloads"]}
        self.assertEqual(len(ids), len(c["nodes"]), "duplicate node ids")
        for n in c["nodes"]:
            self.assertIn(n["workload"], wl, n["id"])
            self.assertTrue(n.get("summary"), n["id"])
        for e in c["edges"]:
            self.assertIn(e["s"], ids, e)
            self.assertIn(e["t"], ids, e)
            self.assertIn(e["kind"], {"nav", "ref", "action"}, e)


    def test_scenarios_reference_real_nodes_and_have_steps(self):
        c = curated()
        self.assertTrue(c.get("scenarios"), "no scenarios")
        self.assertEqual(scenario_problems(c), [])

    def test_scenario_check_catches_bad_data(self):
        c = curated()
        c["scenarios"] = [
            {"id": "a", "label": "A", "group": "AI", "summary": "s", "steps": [{"node": "nope", "do": "x"}]},
            {"id": "b", "label": "B", "group": "AI", "summary": "s", "steps": []},
            {"id": "c d", "label": "C", "group": "AI", "summary": "s", "steps": [{"node": "user", "do": "x"}]},
        ]
        found = " | ".join(scenario_problems(c))
        self.assertIn("a: missing node nope", found)
        self.assertIn("b: no steps", found)
        self.assertIn("c d: id", found)
        c["scenarios"][0]["seeAlso"] = ["zzz"]
        self.assertIn("a: seeAlso zzz", " | ".join(scenario_problems(c)))

    def test_scenarios_are_embedded(self):
        gm, _ = real_map()
        self.assertEqual(len(gm["scenarios"]), len(curated()["scenarios"]))


    def test_legacy_entries_say_what_to_do(self):
        self.assertEqual(legacy_problems(curated()), [])
        bad = {"nodes": [{"id": "x", "legacy": [{"path": "/old"}, {"note": "n"}]}]}
        found = " | ".join(legacy_problems(bad))
        self.assertIn("x: /old needs replacedBy or a note", found)
        self.assertIn("x: a legacy entry has no path", found)

    def test_covers_lists_real_qualified_types(self):
        for n in curated()["nodes"]:
            for fq in n.get("covers") or []:
                self.assertTrue(fq.startswith("microsoft.graph."), f"{n['id']}: {fq}")


class SubserviceTests(unittest.TestCase):
    TPL = "<script>const D=/*__GRAPH_DATA__*/null;</script>"

    def test_curated_subservices_are_complete(self):
        c = curated()
        gm, _ = real_map()
        self.assertEqual(build_page.subservice_problems(gm), ([], []))   # every sub-service holds a curated or generated API
        self.assertEqual(scan.unsorted_nodes(c), [])
        self.assertEqual(sum(len(w["subservices"]) for w in c["workloads"]), 76)
        self.assertEqual(len(c["workloads"]), 16)
        self.assertTrue(all(w.get("family") in {"identity", "collaboration", "security", "ai"} for w in c["workloads"]))

    def test_fields_reach_graph_map_and_page(self):
        gm, _ = real_map()
        self.assertEqual(gm["workloads"][0]["subservices"], curated()["workloads"][0]["subservices"])
        self.assertTrue(all(n.get("subservice") for n in gm["nodes"]))
        html = build_page.render(self.TPL, gm)
        data = json.loads(html.split("const D=", 1)[1].rsplit(";</script>", 1)[0])
        self.assertEqual(data["nodes"][0]["subservice"], curated()["nodes"][0]["subservice"])
        self.assertIn("subservices", data["workloads"][0])

    def _broken(self, change):
        gm, _ = real_map()
        change(gm)
        with self.assertRaises(build_page.BuildError) as cm:
            build_page.render(self.TPL, gm)
        return str(cm.exception)

    def test_build_fails_on_node_without_subservice(self):
        msg = self._broken(lambda gm: gm["nodes"][0].pop("subservice"))
        self.assertIn("no sub-service: user", msg)

    def test_unsorted_allowed_when_asked(self):
        gm, _ = real_map()
        node = next(n for n in gm["nodes"] if n["id"] == "chat")
        node.pop("subservice")
        build_page.render(self.TPL, gm, allow_unsorted=True)  # chats-messages still has chatMessage
        self.assertEqual(build_page.validate(gm, allow_unsorted=True), ["chat"])

    def test_build_fails_on_subservice_from_another_workload(self):
        msg = self._broken(lambda gm: gm["nodes"][0].update(subservice="mail"))
        self.assertIn("user: sub-service 'mail' is not in its workload 'identity'", msg)

    def test_build_fails_on_empty_subservice(self):
        msg = self._broken(lambda gm: gm["workloads"][0]["subservices"].append({"id": "spare", "label": "Spare"}))
        self.assertIn("identity: sub-service 'spare' has no nodes", msg)

    def test_planned_service_may_have_empty_subservices(self):
        gm, _ = real_map()
        w = next(w for w in gm["workloads"] if w["id"] == "education")
        gm["nodes"] = [n for n in gm["nodes"] if n["workload"] != "education"]
        w["planned"] = True
        build_page.render(self.TPL, gm)                       # empty sub-services are fine while planned
        w.pop("planned")
        with self.assertRaises(build_page.BuildError) as cm:
            build_page.render(self.TPL, gm)
        self.assertIn("education: sub-service", str(cm.exception))

    def test_build_fails_on_duplicate_subservice_id(self):
        msg = self._broken(lambda gm: gm["workloads"][0]["subservices"].append({"id": "directory", "label": "Again"}))
        self.assertIn("identity: sub-service id 'directory' is used twice", msg)

    def test_coverage_per_service_adds_up(self):
        with open(os.path.join(ROOT, "data", "coverage.json"), encoding="utf-8") as f:
            prev = json.load(f)
        gm, _ = real_map(prev_coverage=prev)
        svc = gm["coverage"]["services"]
        self.assertEqual([r["workload"] for r in svc], [w["id"] for w in curated()["workloads"]])
        hub = len(curated()["hub"].get("covers") or [])   # entity: the hub stands for it, no service does
        self.assertGreaterEqual(sum(r["onMap"] for r in svc) + hub, gm["coverage"]["onMap"])

    def test_coverage_counts_mapped_and_curated_apart(self):
        with open(os.path.join(ROOT, "data", "coverage.json"), encoding="utf-8") as f:
            prev = json.load(f)
        c = curated()
        gm, _ = scan.build_map(c, None, scan=False, now=D1, prev_coverage=prev)
        cov = gm["coverage"]
        self.assertEqual(cov["curated"], cov["onMap"])         # nothing generated yet
        self.assertTrue(all(r["curated"] == r["onMap"] for r in cov["areas"]))
        # a generated entry counts as mapped, not curated
        INTUNE_CURATED = {n["entityType"] for n in c["nodes"] if n.get("entityType")}
        fq = next(t for t, v in prev["types"].items() if v["status"] == "v1.0" and v["area"] == "deviceManagement"
                  and t not in INTUNE_CURATED)
        c["nodes"].append({"id": "genTest", "label": "Generated test", "workload": "devices", "subservice": "managed-devices",
                           "entityType": fq, "tier": "generated"})
        gm2, _ = scan.build_map(c, None, scan=False, now=D1, prev_coverage=prev)
        cov2 = gm2["coverage"]
        self.assertEqual(cov2["curated"], cov["curated"])
        dev1 = next(r for r in cov["services"] if r["workload"] == "devices")
        dev2 = next(r for r in cov2["services"] if r["workload"] == "devices")
        self.assertEqual((dev2["onMap"], dev2["curated"]), (dev1["onMap"] + (fq not in INTUNE_CURATED), dev1["curated"]))

    def test_same_subservice_id_in_two_workloads_is_fine(self):
        gm, _ = real_map()
        gm["workloads"][1]["subservices"][0]["id"] = "directory"
        for n in gm["nodes"]:
            if n["subservice"] == "privileged-access-pim":
                n["subservice"] = "directory"
        build_page.render(self.TPL, gm)


class BuildPageTests(unittest.TestCase):
    def test_render_escapes_script_close(self):
        tpl = "<script>const D=/*__GRAPH_DATA__*/null;</script>"
        html = build_page.render(tpl, {"meta": {"x": "</script><b>"}, "state": {"big": 1}})
        self.assertNotIn("</script><b>", html)
        self.assertNotIn('"state"', html)


import generate  # noqa: E402

CATALOGUE = {"permissions": {
    "DeviceManagementManagedDevices.Read.All": {"authorizationType": "oAuth2", "schemes": {}, "pathSets": [
        {"schemeKeys": ["DelegatedWork", "Application"], "methods": ["GET"],
         "paths": {"/devicemanagement/manageddevices/{id}": "least=DelegatedWork,Application"}}]},
    "DeviceManagementManagedDevices.ReadWrite.All": {"authorizationType": "oAuth2", "schemes": {}, "pathSets": [
        {"schemeKeys": ["DelegatedWork", "Application"], "methods": ["GET", "PATCH"],
         "paths": {"/devicemanagement/manageddevices/{id}": "least=DelegatedWork,Application"}}]},
    "DeviceManagementConfiguration.Read.All": {"authorizationType": "oAuth2", "schemes": {}, "pathSets": [
        {"schemeKeys": ["Application"], "methods": ["GET"],
         "paths": {"/devicemanagement/devicecompliancepolicies": "least=Application"}}]},
}}
INTUNE_TYPES = {f"microsoft.graph.{t}": {"area": "deviceManagement", "status": "v1.0"} for t in (
    "deviceManagement", "managedDevice", "deviceCompliancePolicy", "androidCompliancePolicy", "iosCompliancePolicy",
    "mobileApp", "mobileLobApp", "win32LobApp", "mobileAppContent", "lonelyType")}
INTUNE_TYPES["microsoft.graph.user"] = {"area": "users", "status": "v1.0"}
WORKLOADS = [{"id": "devices", "subservices": [{"id": "managed-devices"}, {"id": "compliance-configuration"},
                                              {"id": "apps-protection"}, {"id": "intune-admin"}]}]
RULES = {"areas": ["deviceManagement"], "rules": [
    {"path": "/deviceManagement/managedDevices", "to": "devices/managed-devices"},
    {"path": "/deviceManagement/deviceCompliance*", "to": "devices/compliance-configuration"},
    {"path": "/deviceManagement/mobileApps", "to": "devices/apps-protection"},
    {"area": "deviceManagement", "to": "devices/intune-admin"}]}


class GeneratedTierTests(unittest.TestCase):
    def setUp(self):
        self.v1 = scan.parse_csdl(os.path.join(FX, "intune.xml"))
        self.entries = generate.build_entries(self.v1, None, INTUNE_TYPES)
        self.by_type = {e["entityType"].rsplit(".", 1)[1]: e for e in self.entries}

    def test_paths_prefer_own_root_and_add_ids(self):
        md = self.by_type["managedDevice"]
        self.assertEqual(md["path"], "/deviceManagement/managedDevices")      # not /users/{id}/managedDevices
        self.assertEqual(md["itemPath"], "/deviceManagement/managedDevices/{id}")
        self.assertEqual(md["altPaths"], ["/users/{id}/managedDevices"])
        self.assertEqual(self.by_type["deviceManagement"]["path"], "/deviceManagement")   # a singleton has no {id}

    def test_nav_on_a_derived_type_is_reached_through_a_cast(self):
        self.assertEqual(self.by_type["mobileAppContent"]["path"],
                         "/deviceManagement/mobileApps/{id}/microsoft.graph.mobileLobApp/contentVersions")

    def test_variants_fold_into_the_nearest_reachable_base(self):
        dcp = self.by_type["deviceCompliancePolicy"]
        self.assertEqual(dcp["variants"], ["microsoft.graph.androidCompliancePolicy", "microsoft.graph.iosCompliancePolicy"])
        self.assertEqual(self.by_type["mobileApp"]["variants"], ["microsoft.graph.mobileLobApp", "microsoft.graph.win32LobApp"])
        for t in ("androidCompliancePolicy", "win32LobApp", "mobileLobApp"):
            self.assertNotIn(t, self.by_type)
        # every type is an entry or a variant, exactly once
        seen = [e["entityType"] for e in self.entries] + [v for e in self.entries for v in e["variants"]]
        self.assertEqual(sorted(seen), sorted(t for t in self.v1.entities if t != "microsoft.graph.entity"))

    def test_areas_follow_return_types_and_relationships_but_not_entity(self):
        area = scan.assign_areas(self.v1)
        self.assertEqual(area["microsoft.graph.reportResult"], "deviceManagement")   # returned by a bound function
        self.assertEqual(area["microsoft.graph.deviceNote"], "deviceManagement")     # reached by a plain relationship
        self.assertEqual(area["microsoft.graph.lonelyType"], "unrooted")             # an entity-typed nav doesn't count

    def test_paths_fall_back_to_operations_then_relationships(self):
        self.assertEqual(self.by_type["reportResult"]["path"], "/deviceManagement/getReport")
        self.assertEqual(self.by_type["deviceNote"]["path"], "/deviceManagement/managedDevices/{id}/note")
        self.assertEqual(self.by_type["managedDevice"]["path"], "/deviceManagement/managedDevices")   # containment still wins

    def test_unreachable_type_keeps_an_entry_without_a_path(self):
        self.assertIsNone(self.by_type["lonelyType"]["path"])

    def test_entry_has_ops_links_and_scan(self):
        md = self.by_type["managedDevice"]
        self.assertEqual(md["ops"], {"actions": ["retire"], "functions": ["getStatus"]})
        self.assertEqual(md["links"], 3)                     # -> user, -> deviceNote, and <- deviceManagement
        self.assertEqual(md["scan"]["status"], "v1.0")
        self.assertIn("deviceName", md["scan"]["props"])
        self.assertEqual(md["id"], "gen-managedDevice")
        self.assertEqual(md["tier"], "generated")

    def test_labels(self):
        self.assertEqual(generate.label_for("microsoft.graph.iosManagedAppProtection"), "iOS managed app protection")
        self.assertEqual(generate.label_for("microsoft.graph.windowsPhone81CompliancePolicy"), "Windows Phone 8.1 compliance policy")
        self.assertEqual(generate.label_for("microsoft.graph.eBookInstallSummary"), "eBook install summary")
        self.assertEqual(generate.label_for("microsoft.graph.callRecords.callRecord"), "Call record")

    def test_catalogue_least_privilege_keeps_every_name_marked_least(self):
        idx = generate.index_catalogue(CATALOGUE)
        p = generate.permissions_for(self.by_type["managedDevice"], idx)
        self.assertEqual(p["delegated"], "DeviceManagementManagedDevices.Read.All, DeviceManagementManagedDevices.ReadWrite.All")
        self.assertEqual(p["matchedPath"], "/devicemanagement/manageddevices/{id}")
        p = generate.permissions_for(self.by_type["deviceCompliancePolicy"], idx)   # falls back to the collection path
        self.assertEqual((p["delegated"], p["application"]), ("", "DeviceManagementConfiguration.Read.All"))
        self.assertIsNone(generate.permissions_for(self.by_type["lonelyType"], idx))

    def test_catalogue_shape_is_checked(self):
        generate.check_catalogue_shape(CATALOGUE)
        for bad in ({}, {"permissions": {"X": {"paths": {}}}}, {"permissions": {"X": {"pathSets": [{"methods": []}]}}}):
            with self.assertRaises(generate.CatalogueShapeError):
                generate.check_catalogue_shape(bad)

    def test_docs_link_only_when_one_page_fits(self):
        names = {"intune-devices-manageddevice", "user", "intune-a-twin", "intune-b-twin"}
        self.assertTrue(generate.docs_for("microsoft.graph.managedDevice", "deviceManagement", names).endswith("/intune-devices-manageddevice?view=graph-rest-1.0"))
        self.assertTrue(generate.docs_for("microsoft.graph.user", "users", names).endswith("/user?view=graph-rest-1.0"))
        self.assertIsNone(generate.docs_for("microsoft.graph.twin", "deviceManagement", names))     # ambiguous
        self.assertIsNone(generate.docs_for("microsoft.graph.nothing", "deviceManagement", names))

    def test_placement_rules(self):
        def place(t):
            return generate.place(self.by_type[t], RULES["rules"])
        self.assertEqual(place("managedDevice"), ("devices", "managed-devices"))
        self.assertEqual(place("deviceCompliancePolicy"), ("devices", "compliance-configuration"))   # * in a segment
        self.assertEqual(place("mobileAppContent"), ("devices", "apps-protection"))   # prefix: deeper paths match too
        self.assertEqual(place("lonelyType"), ("devices", "intune-admin"))            # area fallback
        typed = [{"type": "microsoft.graph.managedDevice", "to": "devices/intune-admin"}] + RULES["rules"]
        self.assertEqual(generate.place(self.by_type["managedDevice"], typed), ("devices", "intune-admin"))
        self.assertIsNone(generate.place(self.by_type["user"], RULES["rules"]))

    def test_merge_places_only_listed_areas_and_reports_the_rest(self):
        nodes, rep = generate.merge([], self.entries, RULES, WORKLOADS)
        self.assertNotIn("microsoft.graph.user", [n["entityType"] for n in nodes])   # area 'users' isn't listed
        self.assertEqual(rep["unplaced"], [])
        no_fallback = {"areas": ["deviceManagement"], "rules": RULES["rules"][:1]}
        _, rep = generate.merge([], self.entries, no_fallback, WORKLOADS)
        self.assertIn("microsoft.graph.lonelyType", rep["unplaced"])
        _, rep = generate.merge([], self.entries, {"areas": [], "rules": [{"area": "x", "to": "devices/nope"}]}, WORKLOADS)
        self.assertTrue(rep["rules"])

    def test_curated_entry_overrides_generated_and_inherits_variants(self):
        cur = [{"id": "compliance", "label": "Compliance policy", "entityType": "microsoft.graph.deviceCompliancePolicy",
                "workload": "devices", "subservice": "compliance-configuration"},
               {"id": "ios", "label": "iOS policy", "entityType": "microsoft.graph.iosCompliancePolicy"}]
        nodes, rep = generate.merge(cur, self.entries, RULES, WORKLOADS)
        types = [n["entityType"] for n in nodes]
        self.assertNotIn("microsoft.graph.deviceCompliancePolicy", types)
        self.assertEqual(rep["inheritedVariants"], {"compliance": ["microsoft.graph.androidCompliancePolicy"]})  # ios is curated

    def test_build_map_merges_generated_and_build_rule_fails_on_unplaced(self):
        gen = {"meta": {}, "entries": self.entries}
        gm, _ = scan.build_map(curated(), None, scan=False, now=D1, prev_generated=gen, placement=RULES)
        g = [n for n in gm["nodes"] if n.get("tier") == "generated"]
        self.assertTrue(g and all(n["workload"] == "devices" for n in g))
        gm, _ = real_map()
        build_page.render(SubserviceTests.TPL, gm)
        gm["state"]["placement"]["unplaced"] = ["microsoft.graph.lonelyType"]
        with self.assertRaises(build_page.BuildError) as cm:
            build_page.render(SubserviceTests.TPL, gm)
        self.assertIn("lonelyType", str(cm.exception))

    def test_build_fails_when_generated_data_is_missing(self):
        gm, _ = scan.build_map(curated(), None, scan=False, now=D1, prev_generated=None, placement=RULES)
        with self.assertRaises(build_page.BuildError) as cm:
            build_page.render(SubserviceTests.TPL, gm)
        self.assertIn("run a scan", str(cm.exception))

    def test_coverage_counts_variants_as_mapped_not_curated(self):
        with open(os.path.join(ROOT, "data", "coverage.json"), encoding="utf-8") as f:
            prev = copy.deepcopy(json.load(f))
        prev["types"].update(INTUNE_TYPES)
        gen = {"meta": {}, "entries": self.entries}
        gm, _ = scan.build_map(curated(), None, scan=False, now=D1, prev_coverage=prev, prev_generated=gen, placement=RULES)
        dev = next(r for r in gm["coverage"]["services"] if r["workload"] == "devices")
        self.assertEqual((dev["onMap"], dev["curated"]), (10, 2))   # every fixture type; managedDevice and the compliance policy are curated

    def test_real_placement_file_places_every_type(self):
        with open(os.path.join(ROOT, "data", "placement.json"), encoding="utf-8") as f:
            placement = json.load(f)
        with open(os.path.join(ROOT, "data", "generated.json"), encoding="utf-8") as f:
            gen = json.load(f)
        nodes, rep = generate.merge(curated()["nodes"], gen["entries"], placement, curated()["workloads"])
        self.assertEqual((rep["unplaced"], rep["unplacedBeta"], rep["rules"]), ([], [], []))
        self.assertEqual(placement["areas"], ["*"])
        self.assertTrue(nodes)

    def test_every_v1_type_is_mapped(self):
        with open(os.path.join(ROOT, "data", "coverage.json"), encoding="utf-8") as f:
            prev = json.load(f)
        gm, _ = real_map(prev_coverage=prev)
        self.assertEqual(gm["coverage"]["onMap"], gm["coverage"]["v1Types"])
        self.assertEqual(gm["coverage"]["betaOnMap"], gm["coverage"]["betaOnlyTypes"])

    def test_saved_docs_index_applies_offline(self):
        types = scan.coverage_types(self.v1, self.v1)
        pin = {"commit": "abc", "repo": generate.DOCS_REPO, "path": generate.DOCS_DIR}
        gen = scan.build_generated(self.v1, None, types, fetch=False, now=D1,
                                   docs_index=(["intune-devices-manageddevice"], pin))
        md = next(e for e in gen["entries"] if e["entityType"] == "microsoft.graph.managedDevice")
        self.assertTrue(md["docs"].endswith("/intune-devices-manageddevice?view=graph-rest-1.0"))
        self.assertEqual(gen["meta"]["docs"], pin)
        self.assertEqual(gen["meta"]["warnings"], [])

    def test_name_rule_places_types_without_a_path(self):
        rules = [{"name": "lonely*", "to": "devices/intune-admin"}]
        self.assertEqual(generate.place(self.by_type["lonelyType"], rules), ("devices", "intune-admin"))



def explorer_request(n):
    """Python twin of explorerUrl() in web/template.html: (request, version) or None."""
    if n.get("kind") == "gap" or not n.get("path"):
        return None
    req, version = n["path"].split("·")[0].strip(), ("beta" if (n.get("scan") or {}).get("status") == "beta only" else "v1.0")
    if n.get("tier") != "generated":
        m = re.match(r"^GET\s+(\S.*)$", req)
        if not m:
            return None
        req = m.group(1).strip()
    if not req.startswith("/"):
        return None
    req = re.sub(r"^https://graph\.microsoft\.com", "", req)
    v = re.match(r"^/(v1\.0|beta)(/.*)$", req)
    if v:
        version, req = v.group(1), v.group(2)
    return re.sub(r"\{\s*([^}|\s]+)\s*\|[^}]*\}", r"{\1}", req), version


class ExtrasTests(unittest.TestCase):
    def test_graph_explorer_requests_are_clean_get_paths(self):
        gm, _ = real_map()
        made = [(n["id"], explorer_request(n)) for n in gm["nodes"]]
        linked = [(i, r) for i, r in made if r]
        self.assertGreater(len(linked), 1500)
        for i, (req, version) in linked:
            self.assertTrue(req.startswith("/") and not req.startswith("//"), i)
            self.assertNotIn("·", req, i)
            self.assertNotIn("|", req.split("?")[0], i)      # placeholder alternatives are simplified
            self.assertIn(version, ("v1.0", "beta"), i)
        by_id = dict(made)
        self.assertEqual(by_id["user"], ("/users/{id}", "v1.0"))
        self.assertEqual(by_id["sensitiveType"], ("/dataClassification/sensitiveTypes", "beta"))
        self.assertIsNone(by_id["hunting"])                  # POST only: no read-only link
        self.assertIsNone(by_id["exGap"])                    # outside Graph

    def test_template_links_to_explorer_and_permissions_site(self):
        with open(os.path.join(ROOT, "web", "template.html"), encoding="utf-8") as f:
            tpl = f.read()
        self.assertIn("https://developer.microsoft.com/graph/graph-explorer", tpl)
        self.assertIn("https://graphpermissions.merill.net/permission/", tpl)
        self.assertIn(scan.PERM_RE.pattern, tpl)            # the page and the scanner find permission names the same way


if __name__ == "__main__":
    unittest.main()
