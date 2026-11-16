"""
MGC scanner (M365 Graph Cartographer).

Reads the hand-curated map (data/curated.json), checks every node and link
against Microsoft Graph's live $metadata (v1.0 and beta), discovers new links
between nodes on the map, optionally checks permission names against the
Microsoft Graph service principal, and writes:

  graph-map.json   curated content + scan results (what the page renders)
  changelog.json   cumulative list of changes detected between scans
  coverage.json    every entity type grouped by area (its top-level root), with
                   the ones not on the map listed by name

Standard library only, so it runs the same locally, in GitHub Actions and in
an Azure Function. The scanner never edits curated.json.

Usage:
  python scanner/scan.py --curated data/curated.json --out data/graph-map.json
  python scanner/scan.py --no-scan ...          # curated content only
  python scanner/scan.py --v1 v1.xml --beta beta.xml ...   # local CSDL files
  GRAPH_TOKEN=... python scanner/scan.py --permissions ... # also check permission names
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.request
from xml.etree.ElementTree import iterparse

V1_URL = "https://graph.microsoft.com/v1.0/$metadata"
BETA_URL = "https://graph.microsoft.com/beta/$metadata"
GRAPH_APP_ID = "00000003-0000-0000-c000-000000000000"
CHANGELOG_KEEP = 2000
RECENT_KEEP = 60
# "New in Graph" entries per kind that go into recentChanges; the rest are summarised (full list in changelog.json).
NEW_IN_GRAPH_RECENT = 5
# Roots are areas. When a type is equally close to two roots, the earlier one in AREA_PRIORITY wins, then
# other roots alphabetically, then AREA_LAST: broad hubs (/users contains mail, calendars, drives and much more)
# that would otherwise swallow the specific areas.
AREA_PRIORITY = [
    "security", "identityGovernance", "identityProtection", "identity", "policies", "roleManagement",
    "applications", "servicePrincipals", "devices", "directoryRoles", "directory", "auditLogs",
    "deviceManagement", "deviceAppManagement", "copilot", "solutions", "admin", "sites", "drives", "teams",
    "chats", "communications", "reports", "informationProtection", "compliance", "print", "education",
    "employeeExperience", "external", "connections", "storage", "planner",
]
AREA_LAST = ["users", "groups", "me"]
# Polymorphic roots that hold every directory object: they only get types no other root reaches.
AREA_FALLBACK = {"directoryObjects"}
ROOT_ALIASES = {"me": "users", "drive": "drives"}
# Audit-trail navs inherited from baseItem: on almost every files resource and never worth a chord.
DISCOVERY_SKIP_NAVS = {"createdByUser", "lastModifiedByUser"}

PERM_RE = re.compile(r"\b[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)*(?:\.[A-Z][A-Za-z0-9]*)+\b")


# --------------------------------------------------------------------------- CSDL


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


class Schema:
    """Entity types, navigation properties and bound operations from one $metadata document."""

    def __init__(self, entities: dict, ops: dict, roots: dict | None = None):
        self.entities = entities  # fq -> {"base": fq|None, "props": [..], "navs": {name: fq}, "contained": {name}}
        self.ops = ops            # binding fq -> {name: "Action"|"Function"}
        self.roots = roots or {}  # EntityContainer EntitySet/Singleton name -> fq
        self._cache: dict = {}

    def effective(self, fq: str):
        """Own plus inherited properties and navigation properties, or None if the type is absent."""
        if fq in self._cache:
            return self._cache[fq]
        if fq not in self.entities:
            return None
        props, navs, contained, chain, seen = set(), {}, set(), [], set()
        cur = fq
        while cur and cur in self.entities and cur not in seen:
            seen.add(cur)
            chain.append(cur)
            e = self.entities[cur]
            props.update(e["props"])
            for k, v in e["navs"].items():
                navs.setdefault(k, v)
            contained.update(e.get("contained", ()))
            cur = e["base"]
        out = {"props": props, "navs": navs, "contained": contained, "chain": chain}
        self._cache[fq] = out
        return out

    def operation_bound(self, fq: str, name: str) -> bool:
        eff = self.effective(fq)
        chain = eff["chain"] if eff else [fq]
        return any(name in self.ops.get(t, {}) for t in chain)

    def operation_anywhere(self, name: str) -> bool:
        return any(name in names for names in self.ops.values())

    def derived(self) -> dict:
        """base fq -> [directly derived fq]."""
        out: dict[str, list] = {}
        for fq, e in self.entities.items():
            if e["base"]:
                out.setdefault(e["base"], []).append(fq)
        return out


def parse_csdl(source) -> Schema:
    """Parse a CSDL/EDMX document (path or binary file object) with iterparse to keep memory low."""
    aliases: dict[str, str] = {}
    raw_entities: dict[str, dict] = {}
    raw_ops: list[dict] = []
    raw_roots: list[tuple] = []
    ns = alias = None
    cur = None
    op = None

    for event, el in iterparse(source, events=("start", "end")):
        tag = _local(el.tag)
        if event == "start":
            if tag == "Schema":
                ns, alias = el.get("Namespace"), el.get("Alias")
                if alias:
                    aliases[alias] = ns
            elif tag == "EntityType":
                cur = f"{ns}.{el.get('Name')}"
                raw_entities[cur] = {"ctx": (ns, alias), "base": el.get("BaseType"), "props": [], "navs": []}
            elif tag == "Property" and cur:
                raw_entities[cur]["props"].append(el.get("Name"))
            elif tag == "NavigationProperty" and cur:
                raw_entities[cur]["navs"].append((el.get("Name"), el.get("Type"), el.get("ContainsTarget") == "true"))
            elif tag == "EntitySet":
                raw_roots.append((el.get("Name"), el.get("EntityType"), (ns, alias)))
            elif tag == "Singleton":
                raw_roots.append((el.get("Name"), el.get("Type"), (ns, alias)))
            elif tag in ("Action", "Function"):
                op = {"name": el.get("Name"), "kind": tag, "bound": el.get("IsBound") == "true",
                      "binding": None, "ctx": (ns, alias)}
            elif tag == "Parameter" and op and op["bound"] and op["binding"] is None:
                op["binding"] = el.get("Type")
        else:
            if tag == "EntityType":
                cur = None
            elif tag in ("Action", "Function") and op:
                raw_ops.append(op)
                op = None
            if tag in ("EntityType", "ComplexType", "EnumType", "Action", "Function", "Annotations", "EntityContainer"):
                el.clear()

    def resolve(raw, ctx):
        if not raw:
            return None
        m = re.fullmatch(r"Collection\((.*)\)", raw)
        if m:
            raw = m.group(1)
        prefix, _, name = raw.rpartition(".")
        sch_ns, sch_alias = ctx
        if sch_alias and prefix == sch_alias:
            prefix = sch_ns
        else:
            prefix = aliases.get(prefix, prefix)
        return f"{prefix}.{name}"

    entities = {}
    for fq, e in raw_entities.items():
        entities[fq] = {
            "base": resolve(e["base"], e["ctx"]),
            "props": e["props"],
            "navs": {n: resolve(t, e["ctx"]) for n, t, _ in e["navs"]},
            "contained": {n for n, _, c in e["navs"] if c},
        }
    ops: dict[str, dict] = {}
    for o in raw_ops:
        key = resolve(o["binding"], o["ctx"]) if o["bound"] else "(unbound)"
        ops.setdefault(key, {})[o["name"]] = o["kind"]
    roots = {name: resolve(t, ctx) for name, t, ctx in raw_roots}
    return Schema(entities, ops, roots)


# --------------------------------------------------------------------------- fetching


def _open_source(src: str, tmpdir: str):
    """Return a local path for a URL or a path."""
    if re.match(r"https?://", src):
        dest = os.path.join(tmpdir, re.sub(r"\W+", "_", src)[-60:] + ".xml")
        req = urllib.request.Request(src, headers={"Accept": "application/xml", "User-Agent": "mgc-scanner/0.1"})
        with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
        return dest
    return src


def fetch_permissions(token: str) -> dict:
    """Read every Graph permission name from the Microsoft Graph service principal."""
    url = (f"https://graph.microsoft.com/v1.0/servicePrincipals(appId='{GRAPH_APP_ID}')"
           "?$select=appRoles,oauth2PermissionScopes")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        sp = json.load(r)
    return {
        "application": sorted({a["value"] for a in sp.get("appRoles", []) if a.get("value")}),
        "delegated": sorted({s["value"] for s in sp.get("oauth2PermissionScopes", []) if s.get("value")}),
    }


# --------------------------------------------------------------------------- scan


def _status(in_v1: bool, in_beta: bool) -> str:
    return "v1.0" if in_v1 else ("beta only" if in_beta else "not found")


def scan_nodes(curated: dict, v1: Schema | None, beta: Schema | None) -> dict:
    """Return {node_id: scan_result} for every node that can be checked."""
    out = {}
    for n in curated["nodes"]:
        et, action = n.get("entityType"), n.get("action")
        if et:
            e1 = v1.effective(et) if v1 else None
            eb = beta.effective(et) if beta else None
            props = sorted(e1["props"]) if e1 else []
            navs = dict(sorted(e1["navs"].items())) if e1 else {}
            beta_props = sorted((eb["props"] if eb else set()) - set(props))
            beta_navs = sorted(set(eb["navs"] if eb else {}) - set(navs))
            out[n["id"]] = {
                "status": _status(bool(e1), bool(eb)),
                "props": props,
                "navs": navs,
                "betaOnlyProps": beta_props,
                "betaOnlyNavs": beta_navs,
                "baseTypes": (e1 or eb or {"chain": []})["chain"][1:],
            }
        elif action:
            out[n["id"]] = {"status": _status(bool(v1 and v1.operation_anywhere(action)),
                                              bool(beta and beta.operation_anywhere(action)))}
    return out


def scan_edges(curated: dict, v1: Schema | None, beta: Schema | None) -> list:
    by_id = {n["id"]: n for n in curated["nodes"]}
    edges = []
    for e in curated["edges"]:
        e = dict(e)
        src = by_id.get(e["s"], {})
        et = src.get("entityType")
        if e["kind"] == "nav" and et:
            def has(schema):
                eff = schema.effective(et) if schema else None
                return bool(eff and e["nav"] in eff["navs"])
            e["scan"] = _status(has(v1), has(beta))
        elif e["kind"] == "action" and et:
            e["scan"] = _status(bool(v1 and v1.operation_bound(et, e["action"])),
                                bool(beta and beta.operation_bound(et, e["action"])))
        else:
            e["scan"] = "n/a"
        edges.append(e)
    return edges


def discover_edges(curated: dict, v1: Schema | None, beta: Schema | None) -> list:
    """Navigation properties between two nodes on the map that the curated edges don't cover yet."""
    type_to_node = {n["entityType"]: n["id"] for n in curated["nodes"] if n.get("entityType")}
    covered = {(e["s"], e["t"]) for e in curated["edges"]}
    found: dict[tuple, dict] = {}
    for label, schema in (("v1.0", v1), ("beta only", beta)):
        if not schema:
            continue
        for n in curated["nodes"]:
            et = n.get("entityType")
            eff = schema.effective(et) if et else None
            if not eff:
                continue
            for nav, target in eff["navs"].items():
                if nav in DISCOVERY_SKIP_NAVS:
                    continue
                tid = type_to_node.get(target)
                if not tid or tid == n["id"] or (n["id"], tid) in covered:
                    continue
                key = (n["id"], tid, nav)
                if key not in found:
                    found[key] = {"s": n["id"], "t": tid, "kind": "discovered", "nav": nav, "scan": label}
    return sorted(found.values(), key=lambda x: (x["s"], x["t"], x["nav"]))


def check_permissions(curated: dict, perms: dict) -> dict:
    known = set(perms["application"]) | set(perms["delegated"])
    out = {}
    for n in curated["nodes"]:
        text = " ".join((n.get("permissions") or {}).values())
        names = sorted(set(PERM_RE.findall(text)))
        if names:
            out[n["id"]] = {"checked": names, "unknown": [x for x in names if x not in known]}
    return out


# --------------------------------------------------------------------------- coverage


def _short(fq: str) -> str:
    return fq[len("microsoft.graph."):] if fq.startswith("microsoft.graph.") else fq


def _root_order(name: str):
    if name in AREA_PRIORITY:
        return (0, AREA_PRIORITY.index(name), "")
    if name in AREA_LAST:
        return (2, AREA_LAST.index(name), "")
    return (1, 0, name.lower())


def assign_areas(schema: Schema) -> dict:
    """fq -> area for every entity type: the nearest top-level root that reaches it through containment
    (ties go to AREA_PRIORITY), else '<namespace> (namespace)' for sub-namespaces, else 'unrooted'.
    A collection or nav of type X also holds X's derived types, so those count as reached too."""
    derived = schema.derived()

    def with_derived(fq):
        out, stack = [], [fq]
        while stack:
            t = stack.pop()
            if t in schema.entities and t not in out:
                out.append(t)
                stack.extend(derived.get(t, []))
        return out

    area: dict[str, str] = {}

    def spread(seeds):
        queue = []
        for name in seeds:
            for t in with_derived(schema.roots[name]):
                if t not in area:
                    area[t] = ROOT_ALIASES.get(name, name)
                    queue.append(t)
        i = 0
        while i < len(queue):       # breadth first, so the nearest root wins
            t = queue[i]
            i += 1
            eff = schema.effective(t)
            for nav in sorted(eff["contained"]):
                for c in with_derived(eff["navs"].get(nav)):
                    if c not in area:
                        area[c] = area[t]
                        queue.append(c)

    ordered = sorted(schema.roots, key=_root_order)
    spread([r for r in ordered if r not in AREA_FALLBACK])
    spread([r for r in ordered if r in AREA_FALLBACK])   # only claims what no other root reaches
    for fq in schema.entities:
        if fq not in area:
            ns = fq.rpartition(".")[0]
            area[fq] = f"{_short(ns)} (namespace)" if ns.startswith("microsoft.graph.") else "unrooted"
    return area


def coverage_types(v1: Schema, beta: Schema) -> dict:
    """fq -> {"area", "status"} for every v1.0 type and every beta-only type."""
    a1, ab = assign_areas(v1), assign_areas(beta)
    out = {fq: {"area": a1[fq], "status": "v1.0"} for fq in v1.entities}
    for fq in beta.entities:
        if fq not in out:
            out[fq] = {"area": ab[fq], "status": "beta only"}
    return dict(sorted(out.items()))


def summarise_coverage(curated: dict, types: dict, roots: dict, at: str | None) -> dict:
    """Full coverage report (for coverage.json) from a type index and the curated map."""
    on_map = {n["entityType"] for n in curated["nodes"] if n.get("entityType")}
    areas: dict[str, dict] = {}
    for fq, t in types.items():
        a = areas.setdefault(t["area"], {"area": t["area"], "v1": 0, "betaOnly": 0, "onMap": 0,
                                         "onMapTypes": [], "missing": []})
        if t["status"] != "v1.0":
            a["betaOnly"] += 1
            continue
        a["v1"] += 1
        if fq in on_map:
            a["onMap"] += 1
            a["onMapTypes"].append(_short(fq))
        else:
            a["missing"].append(_short(fq))
    rows = sorted(areas.values(), key=lambda r: (-r["v1"], -r["betaOnly"], r["area"].lower()))
    return {
        "at": at,
        "v1Types": sum(r["v1"] for r in rows),
        "betaOnlyTypes": sum(r["betaOnly"] for r in rows),
        "onMap": sum(r["onMap"] for r in rows),
        "areas": rows,
        "roots": roots,
        "types": types,
    }


def coverage_summary(cov: dict | None) -> dict | None:
    """Counts only, for embedding in the page. Names stay in coverage.json."""
    if not cov:
        return None
    return {k: cov[k] for k in ("at", "v1Types", "betaOnlyTypes", "onMap")} | {
        "areas": [{k: r[k] for k in ("area", "v1", "betaOnly", "onMap")} for r in cov["areas"]]}


def coverage_changes(prev: dict | None, cur: dict, today: str) -> list:
    """'New in Graph' entries since the previous coverage report: new v1.0 types, promotions, new roots."""
    if not prev or not prev.get("types"):
        return [{"date": today, "node": None, "kind": "graph-baseline",
                 "text": f"Coverage baseline: {cur['v1Types']:,} v1.0 and {cur['betaOnlyTypes']:,} beta-only entity types."}]
    out = []
    old = prev["types"]
    for fq, t in cur["types"].items():
        if t["status"] != "v1.0":
            continue
        was = old.get(fq)
        if not was:
            out.append({"date": today, "node": None, "kind": "graph-new-type",
                        "text": f"New in Graph v1.0: {_short(fq)} ({t['area']})."})
        elif was["status"] != "v1.0":
            out.append({"date": today, "node": None, "kind": "graph-promoted",
                        "text": f"Promoted from beta to v1.0: {_short(fq)} ({t['area']})."})
    for ver in ("v1.0", "beta"):
        for name in sorted(set(cur["roots"].get(ver, [])) - set((prev.get("roots") or {}).get(ver, []))):
            out.append({"date": today, "node": None, "kind": "graph-new-root",
                        "text": f"New top-level root in {ver}: /{name}."})
    return out


def cap_new_in_graph(changes: list) -> list:
    """Keep at most NEW_IN_GRAPH_RECENT entries per 'New in Graph' kind and summarise the rest."""
    out, seen = [], {}
    for c in changes:
        k = c["kind"]
        if not k.startswith("graph-") or k == "graph-baseline":
            out.append(c)
            continue
        seen[k] = seen.get(k, 0) + 1
        if seen[k] <= NEW_IN_GRAPH_RECENT:
            out.append(c)
    words = {"graph-new-type": "new v1.0 types", "graph-promoted": "promotions to v1.0", "graph-new-root": "new roots"}
    for k, n in seen.items():
        if n > NEW_IN_GRAPH_RECENT:
            out.append({"date": changes[0]["date"], "node": None, "kind": k,
                        "text": f"…and {n - NEW_IN_GRAPH_RECENT} more {words[k]} (full list in changelog.json)."})
    return out


# --------------------------------------------------------------------------- diff


def diff(curated, prev_map, nodes_scan, discovered, perms, today):
    changes = []
    prev_nodes = {n["id"]: n.get("scan") for n in (prev_map or {}).get("nodes", []) if n.get("scan")}
    prev_target = {n["id"]: n.get("entityType") or n.get("action") for n in (prev_map or {}).get("nodes", [])}
    labels = {n["id"]: n["label"] for n in curated["nodes"]}
    targets = {n["id"]: n.get("entityType") or n.get("action") for n in curated["nodes"]}

    def add(node, kind, text):
        changes.append({"date": today, "node": node, "kind": kind, "text": text})

    if not prev_nodes:
        add(None, "baseline", "First schema scan. Results recorded as the baseline.")
    else:
        for nid, cur in nodes_scan.items():
            old = prev_nodes.get(nid)
            lab = labels.get(nid, nid)
            if not old:
                add(nid, "new-node", f"{lab}: scanned for the first time ({cur['status']}).")
                continue
            if prev_target.get(nid) != targets.get(nid):
                # a curation edit, not a schema change: record it once and don't diff the old type's members
                add(nid, "retargeted", f"{lab}: curated type changed from {prev_target.get(nid)} to "
                                       f"{targets.get(nid)} ({cur['status']}). Scan results restarted.")
                continue
            if old.get("status") != cur["status"]:
                add(nid, "status", f"{lab}: moved from {old.get('status')} to {cur['status']}.")
            for field, word in (("props", "property"), ("navs", "relationship")):
                if field not in cur:
                    continue
                a, b = set(old.get(field) or []), set(cur.get(field) or [])
                for x in sorted(b - a):
                    add(nid, f"{field}-added", f"{lab}: new v1.0 {word} '{x}'.")
                for x in sorted(a - b):
                    add(nid, f"{field}-removed", f"{lab}: v1.0 {word} '{x}' no longer present.")
        old_disc = {(e["s"], e["t"], e.get("nav")) for e in (prev_map or {}).get("edges", []) if e["kind"] == "discovered"}
        for e in discovered:
            if (e["s"], e["t"], e["nav"]) not in old_disc:
                add(e["s"], "link-discovered",
                    f"New link {labels[e['s']]} → {labels[e['t']]} via '{e['nav']}' ({e['scan']}).")

    if perms:
        old_names = set(((prev_map or {}).get("state") or {}).get("permissionNames") or [])
        new_names = set(perms["application"]) | set(perms["delegated"])
        if old_names:
            prefixes = {p.split(".")[0] for n in curated["nodes"]
                        for p in PERM_RE.findall(" ".join((n.get("permissions") or {}).values()))}
            fresh = sorted(new_names - old_names)
            related = [p for p in fresh if p.split(".")[0] in prefixes]
            for p in related:
                add(None, "permission-added", f"New Graph permission '{p}'.")
            if len(fresh) > len(related):
                add(None, "permission-added", f"{len(fresh) - len(related)} other new Graph permissions published.")
    return changes


# --------------------------------------------------------------------------- build


def build_map(curated, prev_map=None, v1_src=None, beta_src=None, token=None, scan=True, now=None,
              prev_coverage=None, coverage_out=None):
    """Returns (graph_map, changes). Pass a dict as coverage_out to receive the full coverage report
    (for coverage.json); prev_coverage is the previous one, used for 'New in Graph' entries and by --no-scan."""
    now = now or dt.datetime.now(dt.timezone.utc)
    today = now.date().isoformat()
    v1 = beta = None
    perms = None
    meta = dict(curated["meta"])
    meta["generatedAt"] = now.isoformat(timespec="seconds")

    if scan:
        with tempfile.TemporaryDirectory() as tmp:
            v1 = parse_csdl(_open_source(v1_src or V1_URL, tmp))
            beta = parse_csdl(_open_source(beta_src or BETA_URL, tmp))
        if token:
            perms = fetch_permissions(token)
        meta["scan"] = {
            "at": now.isoformat(timespec="seconds"),
            "v1EntityTypes": len(v1.entities),
            "betaEntityTypes": len(beta.entities),
        }
    else:
        meta["scan"] = (prev_map or {}).get("meta", {}).get("scan")

    if scan:
        nodes_scan = scan_nodes(curated, v1, beta)
        edges = scan_edges(curated, v1, beta)
        discovered = discover_edges(curated, v1, beta)
        changes = diff(curated, prev_map, nodes_scan, discovered, perms, today)
        roots = {"v1.0": sorted(v1.roots), "beta": sorted(beta.roots)}
        cov = summarise_coverage(curated, coverage_types(v1, beta), roots, meta["scan"]["at"])
        changes += coverage_changes(prev_coverage, cov, today)
    else:
        # keep the previous scan results, re-attached to the current curated content
        prev_nodes = {n["id"]: n for n in (prev_map or {}).get("nodes", [])}
        nodes_scan = {k: v["scan"] for k, v in prev_nodes.items() if v.get("scan")}
        prev_edges = {(e["s"], e["t"], e.get("nav") or e.get("action") or e.get("label")): e.get("scan")
                      for e in (prev_map or {}).get("edges", [])}
        edges = []
        for e in curated["edges"]:
            e = dict(e)
            e["scan"] = prev_edges.get((e["s"], e["t"], e.get("nav") or e.get("action") or e.get("label")), "not scanned")
            edges.append(e)
        discovered = [e for e in (prev_map or {}).get("edges", []) if e["kind"] == "discovered"]
        changes = []
        cov = (summarise_coverage(curated, prev_coverage["types"], prev_coverage.get("roots") or {},
                                  prev_coverage.get("at")) if prev_coverage and prev_coverage.get("types") else None)
    # Permission names: fresh from Graph when there is a token, otherwise the list stored by the last
    # token run, so scans without a token (the weekly Actions run) keep checking names instead of dropping them.
    prev_state = (prev_map or {}).get("state") or {}
    if perms:
        perm_names, perm_at = sorted(set(perms["application"]) | set(perms["delegated"])), today
    else:
        prev_scan = (prev_map or {}).get("meta", {}).get("scan") or {}
        perm_names = prev_state.get("permissionNames")
        perm_at = (prev_state.get("permissionNamesAt") or prev_scan.get("permissionsCheckedAt")
                   or (prev_scan.get("at") or "")[:10] or None)
    perm_check = check_permissions(curated, {"application": perm_names, "delegated": []}) if perm_names else {}
    if meta.get("scan"):
        meta["scan"] = dict(meta["scan"])
        meta["scan"]["permissionsChecked"] = bool(perm_names)
        meta["scan"]["permissionCount"] = len(perm_names) if perm_names else None
        meta["scan"]["permissionsCheckedAt"] = perm_at if perm_names else None

    if coverage_out is not None and cov:
        coverage_out.clear()
        coverage_out.update(cov)

    nodes = []
    for n in curated["nodes"]:
        n = dict(n)
        if n["id"] in nodes_scan:
            n["scan"] = nodes_scan[n["id"]]
        if n["id"] in perm_check:
            n["permCheck"] = perm_check[n["id"]]
        nodes.append(n)

    recent = (cap_new_in_graph(changes) + list((prev_map or {}).get("recentChanges", [])))[:RECENT_KEEP]
    state = dict(prev_state)
    if perm_names:
        state["permissionNames"], state["permissionNamesAt"] = perm_names, perm_at

    graph_map = {
        "meta": meta,
        "workloads": curated["workloads"],
        "hub": curated["hub"],
        "nodes": nodes,
        "edges": edges + discovered,
        "scenarios": curated.get("scenarios", []),
        "recentChanges": recent,
        "state": state,
    }
    summary = coverage_summary(cov) or (prev_map or {}).get("coverage")
    if summary:
        graph_map["coverage"] = summary
    return graph_map, changes


def _load(path, default=None):
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return default


def _save(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--curated", default="data/curated.json")
    ap.add_argument("--previous", help="previous graph-map.json (defaults to --out)")
    ap.add_argument("--out", default="data/graph-map.json")
    ap.add_argument("--changelog", default="data/changelog.json")
    ap.add_argument("--coverage", default="data/coverage.json")
    ap.add_argument("--v1", default=V1_URL, help="URL or file for v1.0 $metadata")
    ap.add_argument("--beta", default=BETA_URL, help="URL or file for beta $metadata")
    ap.add_argument("--no-scan", action="store_true", help="merge curated content only; keep previous scan results")
    ap.add_argument("--permissions", action="store_true", help="check permission names (needs GRAPH_TOKEN)")
    a = ap.parse_args(argv)

    curated = _load(a.curated)
    prev = _load(a.previous or a.out)
    token = os.environ.get("GRAPH_TOKEN") if a.permissions else None
    if a.permissions and not token:
        print("warning: --permissions given but GRAPH_TOKEN is not set; skipping permission check", file=sys.stderr)

    cov: dict = {}
    graph_map, changes = build_map(curated, prev, a.v1, a.beta, token, scan=not a.no_scan,
                                   prev_coverage=_load(a.coverage), coverage_out=cov)
    _save(a.out, graph_map)
    if cov:
        _save(a.coverage, cov)
    log = changes + (_load(a.changelog, []) or [])
    _save(a.changelog, log[:CHANGELOG_KEEP])

    s = graph_map["meta"].get("scan") or {}
    print(f"nodes={len(graph_map['nodes'])} edges={len(graph_map['edges'])} "
          f"scanned={'yes' if not a.no_scan else 'no'} v1Types={s.get('v1EntityTypes')} "
          f"betaTypes={s.get('betaEntityTypes')} changes={len(changes)}")
    return graph_map, changes


if __name__ == "__main__":
    main()
