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
        if sc.get("group") not in {"Classic", "AI"}:
            out.append(f"{sid}: group must be Classic or AI")
        if not (sc.get("label") and sc.get("summary")):
            out.append(f"{sid}: needs a label and a summary")
        steps = sc.get("steps") or []
        if not steps:
            out.append(f"{sid}: no steps")
        elif steps[0].get("or"):
            out.append(f"{sid}: the first step can't be an alternative")
        for st in steps:
            if st.get("node") not in ids:
                out.append(f"{sid}: missing node {st.get('node')}")
            if not st.get("do"):
                out.append(f"{sid}: a step has no 'do'")
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

    def test_retargeted_node_is_one_curation_entry_not_schema_changes(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        cur = curated()
        next(n for n in cur["nodes"] if n["id"] == "user")["entityType"] = "microsoft.graph.group"
        _, changes = scan.build_map(cur, first, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"), now=D2)
        user_changes = [c for c in changes if c["node"] == "user"]
        self.assertEqual([c["kind"] for c in user_changes], ["retargeted"])
        self.assertIn("from microsoft.graph.user to microsoft.graph.group", user_changes[0]["text"])

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
        self.assertEqual(area["microsoft.graph.baseItem"], "unrooted")   # no containment path reaches it

    def test_coverage_report_and_page_summary(self):
        gm_out = {}
        gm, _ = scan.build_map(curated(), None, os.path.join(FX, "v1.xml"), os.path.join(FX, "beta.xml"),
                               now=D1, coverage_out=gm_out)
        self.assertEqual(gm_out["v1Types"], len(self.v1.entities))
        self.assertEqual(gm_out["betaOnlyTypes"], 1)                    # sensitivityLabel
        sites = next(a for a in gm_out["areas"] if a["area"] == "sites")
        self.assertIn("driveItem", sites["onMapTypes"])
        self.assertIn("itemRetentionLabel", sites["missing"])
        self.assertEqual(gm["coverage"]["onMap"], gm_out["onMap"])
        self.assertNotIn("missing", json.dumps(gm["coverage"]))         # the page gets counts only
        self.assertNotIn("types", gm["coverage"])

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

    def test_scenarios_are_embedded(self):
        gm, _ = scan.build_map(curated(), None, scan=False, now=D1)
        self.assertEqual(len(gm["scenarios"]), len(curated()["scenarios"]))


class BuildPageTests(unittest.TestCase):
    def test_render_escapes_script_close(self):
        tpl = "<script>const D=/*__GRAPH_DATA__*/null;</script>"
        html = build_page.render(tpl, {"meta": {"x": "</script><b>"}, "state": {"big": 1}})
        self.assertNotIn("</script><b>", html)
        self.assertNotIn('"state"', html)


if __name__ == "__main__":
    unittest.main()
