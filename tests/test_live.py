"""Phase 8: the live read-only runner (web/live, the `live` blocks in data/curated.json, data/samples, the page's
Content Security Policy and auth.html).

The guard and runner tests run the page's own JavaScript under Node (tests/live_harness.js) and are skipped when
Node isn't installed (GitHub's ubuntu-latest runners have it). Everything else is plain Python. The guard tests
loop over every `live` block, so a scenario added to the runner is tested without new tests."""
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scanner"))
import build_page  # noqa: E402

with open(os.path.join(ROOT, "data", "curated.json"), encoding="utf-8") as f:
    CURATED = json.load(f)
ALLOW = build_page.load_allowlist()
GRAPH = "https://graph.microsoft.com"
NODE = shutil.which("node")
PILOT = "copilot-oversharing"


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def live_scenarios():
    return [s for s in CURATED["scenarios"] if any("live" in st for st in s["steps"])]


def harness(tasks):
    p = subprocess.run([NODE, os.path.join(ROOT, "tests", "live_harness.js")], input=json.dumps({"allow": ALLOW, "tasks": tasks}),
                       capture_output=True, text=True, encoding="utf-8", timeout=120)
    if p.returncode:
        raise AssertionError(p.stderr)
    return json.loads(p.stdout)


def samples(sid):
    return build_page.load_samples({"scenarios": CURATED["scenarios"], "liveScenarios": [sid]})[sid]


@unittest.skipUnless(NODE, "Node.js is not installed")
class Guard(unittest.TestCase):
    """The read-only guard (web/live/guard.js): every rule, including writes hidden inside a batch."""
    def check(self, reqs):
        return harness([{"kind": "guard", "req": r} for r in reqs])

    def assertAllowed(self, *reqs):
        for r, v in zip(reqs, self.check(list(reqs))):
            self.assertTrue(v["ok"], f"{r} was refused: {v.get('reason')}")

    def assertRefused(self, *reqs):
        for r, v in zip(reqs, self.check(list(reqs))):
            self.assertFalse(v["ok"], f"{r} was allowed")
            self.assertTrue(v["reason"].strip(), r)

    @staticmethod
    def get(url, scopes=("Sites.Read.All",), **kw):
        return {"method": "GET", "url": url, "scopes": list(scopes), **kw}

    @staticmethod
    def batch(requests, url=GRAPH + "/v1.0/$batch", scopes=("Files.Read.All",)):
        return {"method": "POST", "url": url, "scopes": list(scopes), "body": {"requests": requests}}

    def test_graph_v1_and_beta_only(self):
        self.assertAllowed(self.get(GRAPH + "/v1.0/sites?search=*"), self.get(GRAPH + "/beta/sites/root"))
        self.assertRefused(
            self.get("http://graph.microsoft.com/v1.0/sites"),                  # not https
            self.get("https://graph.microsoft.com.evil.example/v1.0/sites"),    # look-alike host
            self.get("https://evil.example/v1.0/sites"),
            self.get("https://user:pw@graph.microsoft.com/v1.0/sites"),         # credentials in the address
            self.get("https://graph.microsoft.com:8443/v1.0/sites"),            # another port
            self.get(GRAPH + "/v2.0/sites"), self.get(GRAPH + "/sites"), self.get(GRAPH + "/v1.0/"),
            self.get(GRAPH + "/v1.0/../v2.0/sites"),                             # .. resolved before the check
            self.get(GRAPH + "/v1.0/%2e%2e/v2.0/sites"),
            self.get("graph.microsoft.com/v1.0/sites"), self.get("javascript:alert(1)"),
        )

    def test_methods(self):
        for m in ("POST", "PATCH", "PUT", "DELETE", "HEAD", "OPTIONS"):
            self.assertRefused({"method": m, "url": GRAPH + "/v1.0/me/messages", "scopes": ["Mail.Read"]})
        self.assertRefused({"method": "get", "url": GRAPH + "/v1.0/sites", "scopes": ["Sites.Read.All"]},   # exact capitals
                           {"method": "POST", "url": GRAPH + "/v1.0/me/sendMail", "scopes": ["Mail.Read"], "body": {}},
                           self.get(GRAPH + "/v1.0/sites", body={"a": 1}))                          # GET with a body

    def test_read_only_posts_come_from_the_shared_allow_list(self):
        self.assertAllowed(
            {"method": "POST", "url": GRAPH + "/v1.0/search/query", "scopes": ["Files.Read.All"], "body": {"requests": []}},
            {"method": "POST", "url": GRAPH + "/v1.0/drives/b!x/items/01AB/extractSensitivityLabels", "scopes": ["Files.Read.All"]},
            {"method": "POST", "url": GRAPH + "/beta/security/runHuntingQuery", "scopes": ["ThreatHunting.Read.All"], "body": {}})
        self.assertRefused(
            {"method": "POST", "url": GRAPH + "/v1.0/search/query/extra", "scopes": ["Files.Read.All"]},
            {"method": "POST", "url": GRAPH + "/v1.0/drives/b!x/items/01AB/assignSensitivityLabel", "scopes": ["Files.Read.All"]},
            {"method": "POST", "url": GRAPH + "/v1.0/drives/b!x/extractSensitivityLabels", "scopes": ["Files.Read.All"]})
        # one source: take search/query off the list and the guard refuses it
        trimmed = copy.deepcopy(ALLOW)
        trimmed["uris"] = {k: v for k, v in trimmed["uris"].items() if "search/query" not in v["call"]}
        v = harness([{"kind": "guard", "allow": trimmed, "req": {"method": "POST", "url": GRAPH + "/v1.0/search/query", "scopes": ["Files.Read.All"]}}])[0]
        self.assertFalse(v["ok"])
        for entry in ALLOW["uris"].values():   # every POST on the scripts' list is a POST the browser allows
            m, path = entry["call"].split(" ", 1)
            self.assertEqual(m, "POST")
            v = self.check([{"method": "POST", "url": GRAPH + "/v1.0" + path.replace("{id}", "x"), "scopes": ["Files.Read.All"]}])[0]
            self.assertTrue(v["ok"], entry["call"])

    def test_batch_only_when_every_request_inside_is_a_get(self):
        ok = {"id": "1", "method": "GET", "url": "/sites/x/drive"}
        self.assertAllowed(self.batch([ok, {"id": "2", "method": "GET", "url": "/drives/d/root/permissions"}]),
                           self.batch([ok], url=GRAPH + "/beta/$batch"),
                           self.batch([{"id": str(i), "method": "GET", "url": "/sites"} for i in range(20)]),
                           self.batch([{**ok, "headers": {"ConsistencyLevel": "eventual"}}]))
        self.assertRefused(
            self.batch([ok, {"id": "2", "method": "PATCH", "url": "/me", "body": {"x": 1}, "headers": {"Content-Type": "application/json"}}]),
            self.batch([ok, {"id": "2", "method": "DELETE", "url": "/drives/d/items/i"}]),
            self.batch([ok, {"id": "2", "method": "POST", "url": "/search/query", "body": {}}]),   # even an allowed POST
            self.batch([{"id": "1", "method": "get", "url": "/sites"}]),
            self.batch([{"id": "1", "method": "GET", "url": "/sites", "body": {"x": 1}}]),
            self.batch([{"id": "1", "method": "GET", "url": "/$batch"}]),                          # nested batch
            self.batch([{"id": "1", "method": "GET", "url": "https://evil.example/x"}]),
            self.batch([{"id": "1", "method": "GET", "url": "//evil.example/x"}]),
            self.batch([{"id": "1", "method": "GET", "url": "sites"}]),
            self.batch([{"id": "1", "method": "GET", "url": "/../v2.0/sites"}]),
            self.batch([{"id": "1", "method": "GET", "url": "/sites", "headers": {"Authorization": "Bearer x"}}]),
            self.batch([ok, {"id": "1", "method": "GET", "url": "/sites"}]),                       # duplicate id
            self.batch([{"id": str(i), "method": "GET", "url": "/sites"} for i in range(21)]),
            self.batch([]),
            {**self.batch([ok]), "body": {"requests": [ok], "extra": 1}},
            {**self.batch([ok]), "body": "not json"},
            {**self.batch([ok]), "body": json.dumps({"requests": [ok]})},                          # a string, not an object
            {**self.batch([ok]), "url": GRAPH + "/v1.0/$batch?x=1"},
            self.get(GRAPH + "/v1.0/$batch"),
            # fields Graph might read case-insensitively, or that the guard doesn't know
            self.batch([{**ok, "Method": "DELETE"}]), self.batch([{**ok, "Body": {"x": 1}}]), self.batch([{**ok, "URL": "/me"}]),
            self.batch([{**ok, "headers": {"X-HTTP-Method-Override": "DELETE"}}]),
            # inner addresses are resolved by Graph, so they are checked as written
            self.batch([{"id": "1", "method": "GET", "url": "/sites/../drive"}]),
            self.batch([{"id": "1", "method": "GET", "url": "/sites/%2e%2e/drive"}]),
            self.batch([{"id": "1", "method": "GET", "url": "/sites/a%2Fb"}]),
            self.batch([{"id": "1", "method": "GET", "url": "/sites/x y"}]))

    def test_allow_list_placeholders_are_plain_segments(self):
        url = GRAPH + "/v1.0/drives/{d}/items/{i}/extractSensitivityLabels"
        self.assertAllowed({"method": "POST", "url": url.format(d="b!AbC-1_2.x~", i="01ABC"), "scopes": ["Files.Read.All"]})
        for d in ("a%2F..%2F..%2Fme%2FsendMail", "a;b", "a:b", "a%5Cb"):
            self.assertRefused({"method": "POST", "url": url.replace("{d}", d).replace("{i}", "01ABC"), "scopes": ["Files.Read.All"]})

    def test_bodies_are_absent_or_objects(self):
        self.assertRefused(self.get(GRAPH + "/v1.0/sites", body=None), self.get(GRAPH + "/v1.0/sites", body=""),
                           {"method": "POST", "url": GRAPH + "/v1.0/search/query", "scopes": ["Files.Read.All"], "body": "{}"},
                           {"method": "POST", "url": GRAPH + "/v1.0/search/query", "scopes": ["Files.Read.All"], "body": []})

    def test_scopes_must_end_read_or_read_all(self):
        self.assertAllowed(self.get(GRAPH + "/v1.0/me", scopes=["User.Read"]),
                           self.get(GRAPH + "/v1.0/me", scopes=["AuditLogsQuery-Entra.Read.All", "Reports.Read.All"]))
        for bad in (["Files.ReadWrite.All"], ["Mail.Send"], ["Sites.Read.All", "Sites.FullControl.All"], ["Files.Read.All.Evil"],
                    ["Mail.ReadWrite.Read"], ["Mail-ReadWrite.Read"], ["Sites.Manage.Read.All"],
                    ["https://graph.microsoft.com/Files.Read.All"], ["Read"], [""], [], None, ["User.Read "]):
            self.assertRefused(self.get(GRAPH + "/v1.0/me", scopes=bad or []) if bad is not None else
                               {"method": "GET", "url": GRAPH + "/v1.0/me"})

    def test_every_live_block_passes_the_guard(self):
        results = harness([{"kind": "liveBlocks", "scenarios": live_scenarios()}])[0]
        self.assertTrue(results)
        for r in results:
            self.assertTrue(r["verdict"]["ok"], f"{r['where']}: {r['verdict'].get('reason')}")


@unittest.skipUnless(NODE, "Node.js is not installed")
class Runner(unittest.TestCase):
    """The engine (web/live/runner.js) on the sample data and on made-up answers."""
    @classmethod
    def setUpClass(cls):
        cls.runs = {s["id"]: harness([{"kind": "runSamples", "scenario": s, "samples": samples(s["id"])}])[0]
                    for s in live_scenarios() if s["id"] in CURATED.get("liveScenarios", [])}

    def test_every_live_scenario_runs_on_its_samples_without_a_refusal(self):
        for sid, steps in self.runs.items():
            for i, st in enumerate(steps, 1):
                if st is None:
                    continue
                self.assertIsNone(st["refused"], f"{sid} step {i}")
                self.assertGreater(st["rows"], 0, f"{sid} step {i} returned no rows on its sample data")
                self.assertNotIn(404, st["statuses"], f"{sid} step {i} asked for something its sample file doesn't answer")
                self.assertTrue(all(404 not in x for x in st["inner"]), f"{sid} step {i}: a batched request has no sample answer")

    def test_pilot_sample_run(self):
        s1, s2, s3, s4, s5 = self.runs[PILOT]
        self.assertEqual(s1["statuses"], [200, 200])                       # two pages, through @odata.nextLink
        self.assertEqual(s1["counts"], {"Sites found": 8})
        self.assertIn(429, sum(s2["inner"], []))                           # the throttled answer was retried
        self.assertEqual(s2["counts"]["Anyone links"], 2)
        self.assertEqual(s2["counts"]["Organisation-wide links"], 3)
        self.assertEqual(s2["counts"]["Permissions read"], 29)
        self.assertEqual(s2["counts"]["Sites with nothing returned to you"], 1)   # kept, not dropped (keepEmpty)
        self.assertEqual(s3["counts"]["Files found"], 10)
        self.assertEqual(s4["counts"], {"Files checked": 9, "With a label": 5, "Without a label": 4})
        self.assertEqual(len(s4["errors"]), 1)                              # the locked file, in plain words
        self.assertIn("locked", s4["errors"][0])
        self.assertEqual(s5["counts"]["Users in the report"], 6)

    def test_retry_after_is_respected(self):
        r = harness([{"kind": "throttle"}, {"kind": "throttleGivesUp"}])
        self.assertEqual(r[0]["waits"], [7000])
        self.assertEqual(r[0]["statuses"], [429, 200])
        self.assertEqual(r[0]["rows"], 1)
        self.assertEqual(r[1]["attempts"], 3)
        self.assertIn("busy", r[1]["errors"][0])

    def test_token_with_a_write_permission_is_refused(self):
        """A token carries every permission consented for the app; liveSend() stops if any could change data."""
        ok, bad = harness([{"kind": "writeScopes", "scopes": ["openid", "profile", "email", "offline_access", "User.Read", "Sites.Read.All",
                                                                "https://graph.microsoft.com/Reports.Read.All"]},
                           {"kind": "writeScopes", "scopes": ["openid", "Sites.Read.All", "Mail.Send", "Sites.ReadWrite.All", "Directory.AccessAsUser.All"]}])
        self.assertEqual(ok, [])
        self.assertEqual(bad, ["Mail.Send", "Sites.ReadWrite.All", "Directory.AccessAsUser.All"])
        ui = read("web", "live", "ui.js")
        self.assertIn("MGCGuard.writeScopesIn(result.scopes)", ui)
        self.assertLess(ui.index("writeScopesIn(result.scopes)"), ui.index("await fetch("))

    def test_post_is_not_retried_after_503(self):
        r = harness([{"kind": "postNoRetry"}])[0]
        self.assertEqual((r["sent"], r["statuses"]), (1, [503]))

    def test_batches_of_twenty_and_inner_throttling(self):
        r = harness([{"kind": "batching"}])[0]
        self.assertEqual(r["sizes"], [20, 1, 20, 5])   # the throttled request goes again in its own batch
        self.assertEqual(r["waits"], [4000])
        self.assertEqual(r["rows"], 45)
        self.assertEqual(r["errors"], [])

    def test_next_link_to_another_host_is_refused(self):
        r = harness([{"kind": "foreignNextLink"}])[0]
        self.assertEqual(r["sent"], [GRAPH + "/v1.0/sites?search=x"])
        self.assertIn("graph.microsoft.com", r["refused"])

    def test_item_missing_a_value_fails_alone(self):
        r = harness([{"kind": "missingValue"}])[0]
        self.assertEqual(len(r["sent"]), 1)
        self.assertEqual((r["rows"], r["errors"]), (2, 1))

    def test_403_uses_the_steps_own_note(self):
        r = harness([{"kind": "notes"}])[0]
        self.assertTrue(r["errors"][0].startswith("Needs a reports role."))

    def test_csv_export_and_parse(self):
        cols = [{"label": "Name", "from": "a"}, {"label": "Note", "from": "b"}]
        rows = [{"a": "=HYPERLINK(\"x\")", "b": "has, comma"}, {"a": "+1", "b": "line\nbreak"}, {"a": "@SUM(1)", "b": "-2"}]
        text = 'A,B\r\n"x, y","say ""hi"""\r\n1,\r\n'
        r = harness([{"kind": "csv", "columns": cols, "rows": rows, "text": "﻿" + text}])[0]
        lines = r["out"].lstrip("﻿").split("\r\n")
        self.assertEqual(lines[1], '"\'=HYPERLINK(""x"")","has, comma"')   # a formula is neutralised
        self.assertTrue(lines[2].startswith("+1,"))                         # a plain number stays a number
        self.assertEqual(lines[3], "'@SUM(1),-2")
        self.assertEqual(r["parsed"], [{"A": "x, y", "B": 'say "hi"'}, {"A": "1", "B": ""}])


class LiveBlocks(unittest.TestCase):
    """The schema check in build_page.py, and the pilot's data."""
    def gm(self):
        return {"scenarios": copy.deepcopy(CURATED["scenarios"]), "liveScenarios": list(CURATED["liveScenarios"])}

    def pilot(self, gm):
        return next(s for s in gm["scenarios"] if s["id"] == PILOT)

    def test_curated_live_blocks_pass(self):
        self.assertEqual(build_page.live_problems(self.gm(), ALLOW), [])

    def test_pilot_only(self):
        """Phase 8 is a pilot: the Run page is on one scenario until the owner decides (docs/plan-map-all-graph.md)."""
        self.assertEqual(CURATED["liveScenarios"], [PILOT])
        self.assertEqual([s["id"] for s in live_scenarios()], [PILOT])

    def test_schema_check_refuses_bad_blocks(self):
        cases = {
            "method 'PATCH'": lambda lv: lv["calls"][0].update(method="PATCH"),
            "method 'DELETE'": lambda lv: lv["calls"][0].update(method="DELETE"),
            "not on the read-only allow list": lambda lv: lv["calls"][0].update(method="POST", url="/v1.0/me/sendMail"),
            "not read-only": lambda lv: lv.update(scopes=["Sites.ReadWrite.All"]),
            "'says'": lambda lv: lv.pop("says"),
            "unknown field 'scope'": lambda lv: lv.update(scope="x"),
            "unknown field 'headers'": lambda lv: lv["calls"][0].update(headers={"x": 1}),
            "must start with /v1.0/": lambda lv: lv["calls"][0].update(url="https://evil.example/x"),
            "names nothing": lambda lv: lv["calls"][0].update(url="/v1.0/sites/{nope.id}"),
            "'columns'": lambda lv: lv.update(columns=[]),
            "'scopes'": lambda lv: lv.update(scopes=[]),
            "'as'": lambda lv: lv["calls"][0].pop("as"),
            "'pages'": lambda lv: lv["calls"][0].update(pages=500),
        }
        for want, mutate in cases.items():
            gm = self.gm()
            mutate(self.pilot(gm)["steps"][0]["live"])
            errs = build_page.live_problems(gm, ALLOW)
            self.assertTrue(any(want in e for e in errs), f"{want}: {errs}")
        gm = self.gm()
        self.pilot(gm)["steps"][1]["live"]["calls"][0].update(method="POST")   # batched POST
        self.assertTrue(any("only GET calls can be batched" in e for e in build_page.live_problems(gm, ALLOW)))
        gm = self.gm()
        self.pilot(gm)["steps"][2]["live"]["from"]["carry"] = "files"          # carried before any step carries it
        self.assertTrue(any("no earlier step carries" in e for e in build_page.live_problems(gm, ALLOW)))
        gm = self.gm()
        gm["liveScenarios"].append("no-such-scenario")
        self.assertTrue(any("is not a scenario" in e for e in build_page.live_problems(gm, ALLOW)))

    def test_build_fails_on_a_bad_live_block(self):
        gm = self.gm()
        self.pilot(gm)["steps"][0]["live"]["calls"][0]["method"] = "DELETE"
        with self.assertRaises(build_page.BuildError):
            build_page.render(read("web", "template.html"), gm, app={"version": "0.0.0", "released": "2026-01-01"})

    def test_every_live_step_has_a_fictional_sample(self):
        for sid in CURATED["liveScenarios"]:
            s = next(x for x in CURATED["scenarios"] if x["id"] == sid)
            got = samples(sid)
            for i, st in enumerate(s["steps"]):
                if (st.get("live") or {}).get("calls"):
                    self.assertIn(str(i), got, f"{sid} step {i + 1}")
            folder = os.path.join(ROOT, "data", "samples", sid)
            for name in os.listdir(folder):
                text = read("data", "samples", sid, name)
                for host in re.findall(r"https?://([^/\"\s?:]+)", text):
                    self.assertTrue(host.endswith(".example") or host == "graph.microsoft.com", f"{name}: {host} isn't a reserved example domain")
                for mail in re.findall(r"[\w.+-]+@([\w.-]+)", text):
                    self.assertTrue(mail.endswith(".example"), f"{name}: {mail}")
                self.assertNotRegex(text.lower(), r"contoso|fabrikam|northwind|adventure ?works")


class PageSafety(unittest.TestCase):
    """The built page: the Content Security Policy, the MSAL bundle, auth.html and the runner's code rules."""
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        out = os.path.join(cls.tmp, "index.html")
        build_page.main(["--out", out, "--data", os.path.join(ROOT, "data", "graph-map.json"),
                         "--template", os.path.join(ROOT, "web", "template.html"), "--scripts", os.path.join(ROOT, "scripts", "scenarios")])
        cls.html = open(out, encoding="utf-8").read()
        cls.auth = open(os.path.join(cls.tmp, "auth.html"), encoding="utf-8").read()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @staticmethod
    def csp(html):
        return dict((p.split(" ", 1) + [""])[:2] for p in
                    re.search(r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">', html).group(1).split("; "))

    def test_csp_hashes_every_inline_script_and_the_style_block(self):
        pol = self.csp(self.html)
        h = lambda t: "'sha256-" + __import__("base64").b64encode(hashlib.sha256(t.encode()).digest()).decode() + "'"
        scripts = re.findall(r"<script>(.*?)</script>", self.html, re.S)
        self.assertEqual(len(scripts), 2)   # MSAL, then the page
        self.assertEqual(pol["script-src"].split(), [h(s) for s in scripts])
        self.assertEqual(pol["style-src"].split(), [h(s) for s in re.findall(r"<style>(.*?)</style>", self.html, re.S)])
        self.assertEqual(pol["default-src"], "'none'")
        self.assertEqual(pol["connect-src"].split(), ["https://login.microsoftonline.com", "https://graph.microsoft.com"])
        self.assertIn("data:", pol["img-src"].split())         # the favicon is a data: image
        self.assertNotIn("unsafe", " ".join(pol.values()))
        self.assertEqual(self.html.count("Content-Security-Policy\""), 1)
        self.assertLess(self.html.index("Content-Security-Policy"), self.html.index("<script>"))

    def test_no_style_attributes_and_no_inline_handlers(self):
        tpl = read("web", "template.html")
        self.assertNotRegex(tpl, r"<[a-z][^>]*\sstyle\s*=", "use a class, or set el.style from script (the CSP blocks style=\"\")")
        self.assertNotRegex(self.html, r"<[a-z][^>]*\son[a-z]+\s*=\s*[\"']")

    def test_msal_is_built_in_at_the_pinned_version(self):
        man = json.loads(read("vendor", "msal-browser", build_page.MSAL_VERSION, "checksums.json"))
        self.assertEqual(man["version"], build_page.MSAL_VERSION)
        for name, digest in man["sha256"].items():
            with open(os.path.join(ROOT, "vendor", "msal-browser", build_page.MSAL_VERSION, name), "rb") as f:
                self.assertEqual(hashlib.sha256(f.read()).hexdigest(), digest, name)
        self.assertIn(f"/*! @azure/msal-browser v{build_page.MSAL_VERSION} ", self.html)
        self.assertNotRegex(self.html, r"<script[^>]+src=")   # nothing loaded from a CDN

    def test_auth_page_runs_only_the_redirect_bridge(self):
        pol = self.csp(self.auth)
        scripts = re.findall(r"<script>(.*?)</script>", self.auth, re.S)
        self.assertEqual(len(scripts), 2)
        self.assertEqual(pol["script-src"].split(), [build_page.csp_hash(s) for s in scripts])
        self.assertNotIn("connect-src", pol)   # default-src 'none': the bridge page makes no requests
        self.assertIn("broadcastResponseToMainFrame", scripts[1])
        self.assertIn('content="no-referrer"', self.auth)

    def test_runner_code_rules(self):
        code = {n: read("web", "live", n) for n in build_page.LIVE_FILES}
        for name, text in code.items():
            self.assertNotRegex(text, r"\.innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function", name)
            self.assertNotRegex(text, r"XMLHttpRequest|sendBeacon|WebSocket|importScripts|navigator\.sendBeacon", name)
        allc = "\n".join(code.values())
        bare = re.sub(r"/\*.*?\*/", "", allc, flags=re.S)
        bare = re.sub(r"(?m)^\s*//.*$", "", bare)   # comments may mention fetch(); code may not
        self.assertEqual(len(re.findall(r"(?<![\w.])fetch\(", bare)), 1, "liveSend() in ui.js is the only fetch()")
        # the browser keeps the tenant, the client ID and the 'I understand' tick, and nothing else
        self.assertEqual(sorted(set(re.findall(r"'(mgc-live-[a-z]+)'", allc))), ["mgc-live-client", "mgc-live-tenant", "mgc-live-understood"])
        self.assertNotRegex(allc, r"(local|session)Storage\.setItem\(")   # only through store(), with those keys
        self.assertIn("cacheLocation: 'memoryStorage'", code["ui.js"])
        self.assertIn("serverTelemetryEnabled: false", code["ui.js"])
        self.assertIn("redirect: 'manual'", code["ui.js"])   # a Graph redirect to another host is never followed
        self.assertIn("res.type === 'opaqueredirect'", code["ui.js"])

    def test_live_origins_match_the_redirect_uris_in_the_docs(self):
        doc = read("docs", "live-runner.md")
        for o in build_page.LIVE_ORIGINS:
            self.assertTrue(urlparse(o).scheme == "https" or urlparse(o).hostname == "localhost", o)
            self.assertIn(o + build_page.AUTH_PAGE, doc)

    def test_rule_4_is_amended_not_broken(self):
        claude = read("CLAUDE.md")
        rule = re.search(r"4\. \*\*One self-contained page\.\*\*([^\n]+)", claude).group(1)
        self.assertIn("live runner", rule)
        self.assertIn("login.microsoftonline.com", rule)

    def test_how_to_add_a_scenario_checklist(self):
        self.assertIn("How to add a scenario to the runner", read("CLAUDE.md"))


if __name__ == "__main__":
    unittest.main()
