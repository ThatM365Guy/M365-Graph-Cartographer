"""Offline tests for the scanner, using small CSDL fixtures. Run: python -m unittest discover tests"""
import copy
import datetime as dt
import json
import os
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


def curated():
    with open(os.path.join(ROOT, "data", "curated.json"), encoding="utf-8") as f:
        return json.load(f)


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
        disc = edges[("user", "site", "followedSites")]
        self.assertEqual(disc["kind"], "discovered")
        self.assertEqual([c["kind"] for c in changes], ["baseline"])

    def test_second_scan_reports_changes(self):
        first, _ = self.run_scan("v1.xml", "beta.xml")
        second, changes = self.run_scan("v1_later.xml", "beta.xml", prev=first, now=D2)
        texts = " | ".join(c["text"] for c in changes)
        self.assertIn("Sensitivity label: moved from beta only to v1.0", texts)
        self.assertIn("User: new v1.0 property 'employeeLeaveDateTime'", texts)
        self.assertEqual(second["recentChanges"][0]["date"], "2026-11-21")

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


class BuildPageTests(unittest.TestCase):
    def test_render_escapes_script_close(self):
        tpl = "<script>const D=/*__GRAPH_DATA__*/null;</script>"
        html = build_page.render(tpl, {"meta": {"x": "</script><b>"}, "state": {"big": 1}})
        self.assertNotIn("</script><b>", html)
        self.assertNotIn('"state"', html)


if __name__ == "__main__":
    unittest.main()
