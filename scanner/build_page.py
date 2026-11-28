"""
Build the single-file page: web/template.html + graph-map.json -> dist/index.html.

The data is embedded in the page, so it works anywhere (static website,
SharePoint page, Claude artifact, a file opened from disk) with no API calls.

Before embedding, the sub-service structure is checked (see subservice_problems).
The build fails on any problem, so the expanding ring never has a branch with
nothing in it or a node it can't place. The one exception is a workload marked "planned": true, a
service added before its APIs are mapped, whose sub-services may still be empty. Pass --allow-unsorted to build anyway
when the only problem is nodes with no sub-service yet: the page then shows them
under a temporary "Unsorted" sub-service until a person files them.

Usage:
  python scanner/build_page.py --data data/graph-map.json --template web/template.html --out dist/index.html
"""
import argparse
import base64
import hashlib
import json
import os
import re

MARKER = "/*__GRAPH_DATA__*/null"
# The open service fans its sub-services over 160 degrees and an open sub-service needs room for 8 API bubbles. With
# more than 8 sub-services the open one's share runs out (MGC.check() finds overlaps at 9), so the build stops first.
MAX_SUBSERVICES = 8


class BuildError(ValueError):
    pass


def subservice_problems(graph_map: dict) -> tuple[list, list]:
    """Returns (errors, unsorted). errors are readable strings; unsorted lists the ids of nodes with no
    sub-service at all, which --allow-unsorted tolerates."""
    errors, unsorted = [], []
    subs, planned = {}, set()
    for w in graph_map.get("workloads", []):
        if w.get("planned"):
            planned.add(w["id"])
        seen = set()
        for s in w.get("subservices") or []:
            sid = s.get("id")
            if not sid or not s.get("label"):
                errors.append(f"{w['id']}: every sub-service needs an id and a label")
            if sid in seen:
                errors.append(f"{w['id']}: sub-service id '{sid}' is used twice")
            seen.add(sid)
        if not seen:
            errors.append(f"{w['id']}: workload has no sub-services")
        if len(seen) > MAX_SUBSERVICES:
            errors.append(f"{w['id']}: {len(seen)} sub-services, but the ring fits at most {MAX_SUBSERVICES} "
                          f"(merge some, or change layoutExplore() in web/template.html and rerun MGC.check())")
        subs[w["id"]] = seen
    used = set()
    for n in graph_map.get("nodes", []):
        ss = n.get("subservice")
        if not ss:
            unsorted.append(n["id"])
        elif ss not in subs.get(n.get("workload"), set()):
            errors.append(f"{n['id']}: sub-service '{ss}' is not in its workload '{n.get('workload')}'")
        else:
            used.add((n["workload"], ss))
    for wid, seen in subs.items():
        if wid in planned:   # a planned service shows its sub-services before anything is mapped in them
            continue
        for sid in sorted(seen - {None}):
            if (wid, sid) not in used:
                errors.append(f"{wid}: sub-service '{sid}' has no nodes")
    return errors, unsorted


def placement_problems(graph_map: dict) -> list:
    """The completeness rule: every v1.0 type in an area listed in data/placement.json must be on the map
    (as an entry, a folded variant or a curated node). scan.py records what no rule placed in state.placement."""
    rep = (graph_map.get("state") or {}).get("placement")
    if not rep:
        return []
    errors = list(rep.get("rules") or [])
    if rep.get("missing"):
        errors.append(rep["missing"])
    if rep.get("unplaced"):
        errors.append(f"{len(rep['unplaced'])} v1.0 type(s) in {', '.join(rep['areas'])} not placed: "
                      f"{', '.join(t.rsplit('.', 1)[-1] for t in rep['unplaced'])} (add a rule to data/placement.json)")
    return errors


def validate(graph_map: dict, allow_unsorted: bool = False) -> list:
    """Raises BuildError if the sub-service structure or the placement rule is broken. Returns the unsorted node ids."""
    errors, unsorted = subservice_problems(graph_map)
    errors += placement_problems(graph_map)
    if unsorted and not allow_unsorted:
        errors.append(f"no sub-service: {', '.join(unsorted)} (set node.subservice in curated.json, "
                      f"or build with --allow-unsorted to show them under 'Unsorted')")
    if errors:
        raise BuildError("sub-service or placement check failed:\n  " + "\n  ".join(errors))
    return unsorted


TESTED_RX = re.compile(r"^Tested:\s*(\d{4}-\d{2}-\d{2})", re.M)


def load_scripts(folder: str) -> dict:
    """The read-only scenario scripts (scripts/scenarios/<scenario-id>.ps1), embedded so the page can offer them as
    downloads without fetching anything. tested is the date in the header's 'Tested:' line, or '' for 'not yet'.
    A missing folder gives {} (the Azure Function package has no scripts), and the page then shows no download links."""
    out = {}
    if not os.path.isdir(folder):
        return out
    for name in sorted(os.listdir(folder)):
        if name.endswith(".ps1"):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                text = f.read()
            m = TESTED_RX.search(text.split("#>", 1)[0])
            out[name[:-4]] = {"text": text, "tested": m.group(1) if m else ""}
    return out


VERSION_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "version.json")
SEMVER_RX = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")


def load_version(path: str = VERSION_FILE) -> dict:
    """The app version, kept in one file (data/version.json): {"version": "0.10.0", "released": "2026-11-28"}.
    It goes into the header, the About popup and the footer through the {{version}} and {{released}} markers."""
    try:
        with open(path, encoding="utf-8") as f:
            app = json.load(f)
    except (OSError, ValueError) as e:
        raise BuildError(f"cannot read the app version from {path}: {e}")
    v, rel = str(app.get("version", "")), str(app.get("released", ""))
    if not SEMVER_RX.match(v):
        raise BuildError(f"{path}: version '{v}' is not semantic versioning (for example 0.10.0)")
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", rel):
        raise BuildError(f"{path}: released '{rel}' is not a date (YYYY-MM-DD)")
    return {"version": v, "released": rel}


def release_date(iso: str) -> str:
    """2026-11-28 -> 28 Nov 2026, the way the page writes dates."""
    y, m, d = (int(x) for x in iso.split("-"))
    return f"{d} {'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split()[m - 1]} {y}"


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------- Phase 8: live read-only runner ----------------
# The runner's code (web/live), MSAL (vendor/msal-browser, pinned), the shared read-only allow list
# (scripts/allowlist.json) and the sample responses (data/samples/<scenario-id>/step-<n>.json) are built into the
# page, so it still makes no network calls until someone chooses to sign in. See docs/live-runner.md.
LIVE_MARKER = "/*__LIVE_CODE__*/"
MSAL_MARKER = "/*__MSAL__*/"
CSP_MARKER = "{{csp}}"
LIVE_FILES = ("guard.js", "runner.js", "ui.js")
MSAL_VERSION = "5.29.1"
# Pages that may sign in: each must be registered as a single-page application redirect URI (<page>auth.html) in the
# person's own app registration. Anywhere else (a file, an artifact, another host) the Run page offers sample data only.
LIVE_ORIGINS = ["https://thatm365guy.github.io/M365-Graph-Cartographer/", "http://localhost:8765/"]
AUTH_PAGE = "auth.html"
CSP_CONNECT = "https://login.microsoftonline.com https://graph.microsoft.com"

SCOPE_RX = re.compile(r"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*\.Read(\.All)?$")
WRITE_WORDS = re.compile(r"Write|Send|Manage|FullControl|Create|Delete|Update", re.I)   # as in web/live/guard.js
PLACEHOLDER_RX = re.compile(r"\{([A-Za-z0-9_.]+)\}")
LIVE_KEYS = {"says", "scopes", "whyScope", "caveat", "input", "from", "calls", "columns", "counts", "carry", "skip", "notes"}
CALL_KEYS = {"method", "url", "body", "rows", "as", "batch", "pages", "pageBy", "format", "what", "keepEmpty", "perItemErrors"}
CARRY_KEYS = {"name", "key", "label", "keep", "tick", "max", "help"}


def load_allowlist(root: str = ROOT) -> dict:
    with open(os.path.join(root, "scripts", "allowlist.json"), encoding="utf-8") as f:
        return json.load(f)


def post_patterns(allow: dict) -> list:
    """The POST calls on the read-only allow list as regexes over the path after /v1.0 or /beta ({x} = one segment).
    The same rule as postRules() in web/live/guard.js."""
    out = []
    for v in (allow.get("uris") or {}).values():
        m = re.match(r"^\s*([A-Z]+)\s+(/\S*)\s*$", str(v.get("call", "")))
        if m and m.group(1) == "POST":
            parts = ["[^/]+" if re.fullmatch(r"\{[^}]+\}", s) else re.escape(s) for s in m.group(2).split("/")]
            out.append(re.compile("^" + "/".join(parts) + "$"))
    return out


def _strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, list):
        for x in v:
            yield from _strings(x)
    elif isinstance(v, dict):
        for x in v.values():
            yield from _strings(x)


def live_problems(graph_map: dict, allow: dict) -> list:
    """Schema check for the `live` blocks on scenario steps and the liveScenarios list. Fails on a malformed block,
    a request that isn't GET or an allowed read-only POST, or a scope that doesn't end .Read or .Read.All."""
    errors = []
    scen = {s.get("id"): s for s in graph_map.get("scenarios", [])}
    posts = post_patterns(allow)
    listed = graph_map.get("liveScenarios", [])
    if not isinstance(listed, list) or not all(isinstance(x, str) for x in listed):
        return ["liveScenarios must be a list of scenario ids"]
    for sid in listed:
        if sid not in scen:
            errors.append(f"liveScenarios: '{sid}' is not a scenario")
        elif not any(st.get("live", {}).get("calls") for st in scen[sid].get("steps", [])):
            errors.append(f"liveScenarios: '{sid}' has no step with a live block that makes a call")
    for s in graph_map.get("scenarios", []):
        carries = set()
        for i, st in enumerate(s.get("steps", []), 1):
            lv = st.get("live")
            if lv is None:
                continue
            where = f"{s.get('id')} step {i} live"
            if not isinstance(lv, dict):
                errors.append(f"{where}: must be an object")
                continue
            errors += [f"{where}: unknown field '{k}'" for k in sorted(set(lv) - LIVE_KEYS)]
            if not isinstance(lv.get("says"), str) or not lv["says"].strip():
                errors.append(f"{where}: 'says' (one plain sentence on what the step does and doesn't do) is required")
            for k in ("whyScope", "caveat"):
                if k in lv and not isinstance(lv[k], str):
                    errors.append(f"{where}: '{k}' must be text")
            calls = lv.get("calls") or []
            if not isinstance(calls, list):
                errors.append(f"{where}: 'calls' must be a list")
                calls = []
            if not calls and not lv.get("skip"):
                errors.append(f"{where}: needs 'calls', or 'skip' for a step that only changes data")
            scopes = lv.get("scopes")
            if calls:
                if not isinstance(scopes, list) or not scopes:
                    errors.append(f"{where}: 'scopes' must list the delegated permissions the calls need")
                else:
                    errors += [f"{where}: scope '{x}' is not read-only (only names ending .Read or .Read.All)"
                               for x in scopes if not isinstance(x, str) or not SCOPE_RX.match(x) or WRITE_WORDS.search(x)]
            names = {"input"}
            frm = lv.get("from")
            if frm is not None:
                if not isinstance(frm, dict) or set(frm) != {"carry", "as"}:
                    errors.append(f"{where}: 'from' must be {{\"carry\": <name>, \"as\": <name>}}")
                else:
                    if frm["carry"] not in carries:
                        errors.append(f"{where}: carries '{frm['carry']}' but no earlier step carries it forward")
                    names.add(frm["as"])
            for j, c in enumerate(calls, 1):
                cw = f"{where} call {j}"
                if not isinstance(c, dict):
                    errors.append(f"{cw}: must be an object")
                    continue
                errors += [f"{cw}: unknown field '{k}'" for k in sorted(set(c) - CALL_KEYS)]
                method, url = c.get("method"), c.get("url")
                if not isinstance(url, str) or not re.match(r"^/(v1\.0|beta)/\S+$", url):
                    errors.append(f"{cw}: 'url' must start with /v1.0/ or /beta/")
                    url = ""
                path = re.sub(r"^/(v1\.0|beta)", "", url.split("?", 1)[0])
                if method == "GET":
                    if "body" in c:
                        errors.append(f"{cw}: a GET has no body")
                elif method == "POST":
                    if c.get("batch"):
                        errors.append(f"{cw}: only GET calls can be batched")
                    if not any(p.match(PLACEHOLDER_RX.sub("x", path)) for p in posts):
                        errors.append(f"{cw}: POST {path} is not on the read-only allow list (scripts/allowlist.json)")
                else:
                    errors.append(f"{cw}: method '{method}' is not allowed (GET, or POST on the read-only allow list)")
                if not isinstance(c.get("as"), str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", c.get("as") or ""):
                    errors.append(f"{cw}: 'as' (the name each result is known by) is required")
                for txt in [url, *(_strings(c.get("body")))]:
                    for ph in PLACEHOLDER_RX.findall(txt):
                        if ph.split(".")[0] not in names:
                            errors.append(f"{cw}: placeholder {{{ph}}} names nothing this step has")
                        if ph == "input" and not isinstance(lv.get("input"), dict):
                            errors.append(f"{cw}: uses {{input}} but the step has no 'input'")
                if "pages" in c and not (isinstance(c["pages"], int) and 1 <= c["pages"] <= 20):
                    errors.append(f"{cw}: 'pages' must be a whole number from 1 to 20")
                if c.get("pageBy") not in (None, "search"):
                    errors.append(f"{cw}: 'pageBy' can only be 'search'")
                if c.get("format") not in (None, "csv"):
                    errors.append(f"{cw}: 'format' can only be 'csv'")
                names.add(c.get("as"))
            if calls:
                cols = lv.get("columns")
                if not isinstance(cols, list) or not cols or not all(isinstance(x, dict) and x.get("label") and x.get("from") for x in cols):
                    errors.append(f"{where}: 'columns' must list {{label, from}} field mappings")
                if not isinstance(lv.get("counts", []), list) or not all(isinstance(x, dict) and x.get("label") for x in lv.get("counts", [])):
                    errors.append(f"{where}: 'counts' must list {{label}} headline counts")
            for k in lv.get("skip") or []:
                if not (isinstance(k, dict) and k.get("what") and k.get("why")):
                    errors.append(f"{where}: each 'skip' entry needs 'what' and 'why'")
            if not all(re.fullmatch(r"\d{3}", str(k)) and isinstance(v, str) for k, v in (lv.get("notes") or {}).items()):
                errors.append(f"{where}: 'notes' maps an HTTP status (such as 403) to plain text")
            cr = lv.get("carry")
            if cr is not None:
                if not isinstance(cr, dict) or not {"name", "key", "keep"} <= set(cr) or set(cr) - CARRY_KEYS:
                    errors.append(f"{where}: 'carry' needs name, key and keep (and may have label, tick, max, help)")
                else:
                    carries.add(cr["name"])
    return errors


def load_samples(graph_map: dict, root: str = ROOT) -> dict:
    """{scenario-id: {step index: [rules]}} for every live step of every scenario on liveScenarios."""
    out = {}
    scen = {s["id"]: s for s in graph_map.get("scenarios", [])}
    for sid in graph_map.get("liveScenarios", []):
        steps = {}
        for i, st in enumerate(scen.get(sid, {}).get("steps", [])):
            if not (st.get("live") or {}).get("calls"):
                continue
            p = os.path.join(root, "data", "samples", sid, f"step-{i + 1}.json")
            try:
                with open(p, encoding="utf-8") as f:
                    steps[str(i)] = json.load(f)["responses"]
            except (OSError, ValueError, KeyError) as e:
                raise BuildError(f"{sid} step {i + 1} has a live block but no usable sample file {p}: {e}")
        out[sid] = steps
    return out


def load_live(root: str = ROOT) -> dict:
    """The runner's code, the pinned MSAL bundle and redirect bridge, and the allow list."""
    code = []
    for name in LIVE_FILES:
        with open(os.path.join(root, "web", "live", name), encoding="utf-8") as f:
            code.append(f"/* ---- web/live/{name} ---- */\n" + f.read())
    vend = os.path.join(root, "vendor", "msal-browser", MSAL_VERSION)
    with open(os.path.join(vend, "msal-browser.min.js"), encoding="utf-8") as f:
        msal = f.read()
    with open(os.path.join(vend, "msal-redirect-bridge.min.js"), encoding="utf-8") as f:
        bridge = f.read()
    for name, text in [*zip(LIVE_FILES, code), ("msal-browser.min.js", msal), ("msal-redirect-bridge.min.js", bridge)]:
        if re.search(r"</script|<!--", text, re.I):
            raise BuildError(f"{name} contains '</script' or '<!--', which would break the inline <script>")
    return {"code": "\n".join(code), "msal": msal, "bridge": bridge, "allow": load_allowlist(root)}


def csp_hash(text: str) -> str:
    return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode("utf-8")).digest()).decode("ascii") + "'"


def page_csp(html: str) -> str:
    """The Content Security Policy for the page: inline scripts and the <style> block by hash (no 'unsafe-inline';
    the page has no style="" attributes), data: images for the favicon, and connections only to Microsoft sign-in and
    Microsoft Graph. frame-src covers MSAL's silent sign-in frame, which returns to auth.html on the same site."""
    scripts = [csp_hash(m) for m in re.findall(r"<script>(.*?)</script>", html, re.S)]
    styles = [csp_hash(m) for m in re.findall(r"<style>(.*?)</style>", html, re.S)]
    return ("default-src 'none'; "
            f"script-src {' '.join(scripts)}; style-src {' '.join(styles)}; img-src 'self' data:; "
            f"connect-src {CSP_CONNECT}; frame-src 'self' https://login.microsoftonline.com; "
            "base-uri 'none'; form-action 'none'; object-src 'none'")


def render_auth(bridge: str) -> str:
    """auth.html: the redirect page MSAL's pop-up returns to. It runs only MSAL's redirect bridge, which hands the
    sign-in response to the MGC tab and closes the pop-up."""
    run = ("msalRedirectBridge.broadcastResponseToMainFrame().catch(function(){document.getElementById('m').textContent="
           "'This page only finishes a sign-in started from M365 Graph Cartographer. You can close it.';});")
    csp = (f"default-src 'none'; script-src {csp_hash(bridge)} {csp_hash(run)}; "
           "base-uri 'none'; form-action 'none'; object-src 'none'")
    return ('<!DOCTYPE html>\n<html lang="en-GB">\n<head>\n<meta charset="utf-8">\n'
            f'<meta http-equiv="Content-Security-Policy" content="{csp}">\n'
            '<meta name="referrer" content="no-referrer">\n<title>Microsoft Authentication</title>\n</head>\n<body>\n'
            '<p id="m">Finishing sign-in for M365 Graph Cartographer. This window closes by itself.</p>\n'
            f"<script>{bridge}</script>\n<script>{run}</script>\n</body>\n</html>\n")


def render(template: str, graph_map: dict, allow_unsorted: bool = False, scripts: dict | None = None,
           app: dict | None = None, live: dict | None = None) -> str:
    if "nodes" in graph_map:
        validate(graph_map, allow_unsorted)
    app = app or load_version()
    # before the data goes in, so text in the data can never be taken for a marker
    template = template.replace("{{version}}", app["version"]).replace("{{released}}", release_date(app["released"]))
    data = {k: v for k, v in graph_map.items() if k != "state"}
    if scripts:
        data["scripts"] = scripts
    has_live = LIVE_MARKER in template
    if has_live:
        live = live or load_live()
        errs = live_problems(graph_map, live["allow"])
        if errs:
            raise BuildError("live runner check failed:\n  " + "\n  ".join(errs))
        data["live"] = {"allow": {"uris": live["allow"].get("uris", {})}, "samples": load_samples(graph_map),
                        "origins": LIVE_ORIGINS, "authPage": AUTH_PAGE, "msal": MSAL_VERSION}
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # keep the JSON from closing the <script> element early
    payload = payload.replace("</", "<\\/").replace("<!--", "<\\!--")
    if MARKER not in template:
        raise ValueError(f"template is missing the data marker {MARKER}")
    if has_live:
        template = template.replace(LIVE_MARKER, live["code"], 1)
        if MSAL_MARKER not in template:
            raise ValueError(f"template is missing the MSAL marker {MSAL_MARKER}")
        template = template.replace(MSAL_MARKER, live["msal"], 1)
    html = template.replace(MARKER, payload, 1)
    if CSP_MARKER in html:
        if re.search(r"<[a-z][^>]*\sstyle\s*=", html, re.I):
            raise BuildError("the page has a style=\"\" attribute, which its Content Security Policy blocks "
                             "(use a class, or set el.style from script)")
        html = html.replace(CSP_MARKER, page_csp(html), 1)   # the marker sits in <head>, outside every script
    return html


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data/graph-map.json")
    ap.add_argument("--template", default="web/template.html")
    ap.add_argument("--out", default="dist/index.html")
    ap.add_argument("--scripts", default="scripts/scenarios", help="folder of scenario scripts to embed (missing is fine)")
    ap.add_argument("--allow-unsorted", action="store_true",
                    help="build even if some nodes have no sub-service (shown under 'Unsorted')")
    ap.add_argument("--version-file", default=VERSION_FILE, help="the app version (default data/version.json)")
    a = ap.parse_args(argv)
    with open(a.template, encoding="utf-8") as f:
        template = f.read()
    with open(a.data, encoding="utf-8") as f:
        graph_map = json.load(f)
    try:
        live = load_live() if LIVE_MARKER in template else None
        html = render(template, graph_map, a.allow_unsorted, load_scripts(a.scripts), load_version(a.version_file), live)
    except BuildError as e:
        raise SystemExit(f"build_page: {e}")
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(html)
    if live:   # the pop-up sign-in returns to this page, next to index.html
        with open(os.path.join(os.path.dirname(os.path.abspath(a.out)), AUTH_PAGE), "w", encoding="utf-8") as f:
            f.write(render_auth(live["bridge"]))
    unsorted = subservice_problems(graph_map)[1]
    print(f"wrote {a.out} ({len(html) // 1024} KB, v{load_version(a.version_file)['version']})" + (f"; unsorted: {', '.join(unsorted)}" if unsorted else ""))


if __name__ == "__main__":
    main()
