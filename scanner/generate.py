"""
Generated tier: an entry for every v1.0 entity type in Microsoft Graph, built from $metadata.

Standard library only, like scan.py. Nothing here is written by hand and nothing is made up: each entry has
the paths that reach it from a top-level root, its properties, relationships and bound operations, the
variants folded into it, permissions from Microsoft's path-to-permission catalogue (marked "generated, not
checked") and a Microsoft Learn link when the docs repository has a page for the type.

  build_entries()    schema -> entries (one per addressable type; variants folded into their base)
  fetch_catalogue()  permissions/new/permissions.json from microsoftgraph/microsoft-graph-devx-content, pinned
  fetch_docs_index() the file names of the v1.0 resource pages in microsoftgraph/microsoft-graph-docs-contrib
  place()            data/placement.json rules -> workload and sub-service per entry
  merge()            curated entries override generated ones for the same type

The scanner writes every entry to data/generated.json. Only the areas listed in placement.json reach the map,
so placement can be extended with `scan.py --no-scan`, without a new scan.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import urllib.request
from collections import deque

CATALOGUE_REPO = "microsoftgraph/microsoft-graph-devx-content"
CATALOGUE_PATH = "permissions/new/permissions.json"
DOCS_REPO = "microsoftgraph/microsoft-graph-docs-contrib"
DOCS_DIR = "api-reference/v1.0/resources"
LEARN_URL = "https://learn.microsoft.com/graph/api/resources/{}?view=graph-rest-1.0"
INTUNE_AREAS = {"deviceManagement", "deviceAppManagement"}
NOT_A_BASE = {"microsoft.graph.entity"}   # every type derives from it; never fold into it
ID_PREFIX = "gen-"


class CatalogueShapeError(ValueError):
    """permissions.json no longer has the shape this code reads."""


# --------------------------------------------------------------------------- names

ACRONYMS = {"ios": "iOS", "ipados": "iPadOS", "macos": "macOS", "mdm": "MDM", "vpp": "VPP", "lob": "LOB", "pc": "PC",
            "id": "ID", "oem": "OEM", "msi": "MSI", "appx": "AppX", "ebook": "eBook", "ebooks": "eBooks", "os": "OS",
            "url": "URL", "apns": "APNs", "wip": "WIP", "uri": "URI", "dep": "DEP", "edm": "EDM", "api": "API",
            "sms": "SMS", "rbac": "RBAC", "sku": "SKU", "dmg": "DMG", "ui": "UI"}
PROPER = {"windows": "Windows", "android": "Android", "apple": "Apple", "microsoft": "Microsoft", "office": "Office",
          "exchange": "Exchange", "intune": "Intune", "defender": "Defender", "edge": "Edge", "teams": "Teams",
          "sharepoint": "SharePoint", "onedrive": "OneDrive", "autopilot": "Autopilot", "hello": "Hello",
          "business": "Business", "store": "Store", "cloud": "Cloud", "win32": "Win32", "web": "web"}


PHRASES = [(r"\b[Ww]indows phone 81\b", "Windows Phone 8.1"), (r"\bWindows 81\b", "Windows 8.1"), (r"\b[Ww]in 32\b", "Win32"),
           (r"\b[Ww]indows information protection\b", "Windows Information Protection"),
           (r"\b[Cc]onditional access\b", "Conditional Access"), (r"\bapp locker\b", "AppLocker"),
           (r"\b([Oo])n premises\b", r"\1n-premises")]


def label_for(fq: str) -> str:
    """'microsoft.graph.iosManagedAppProtection' -> 'iOS managed app protection'."""
    name = fq.rsplit(".", 1)[-1]
    name = name.replace("iPadOS", "Ipados").replace("macOS", "Macos").replace("AppX", "Appx").replace("EBook", "Ebook")
    if name.startswith("eBook"):
        name = "ebook" + name[5:]
    words = re.findall(r"[A-Z]+(?=[A-Z][a-z]|\d|$)|[A-Z]?[a-z]+|\d+", name)
    out = []
    for i, w in enumerate(words):
        lw = w.lower()
        if lw in ACRONYMS:
            out.append(ACRONYMS[lw])
        elif lw in PROPER and (i == 0 or PROPER[lw][0].isupper()):
            out.append(PROPER[lw])
        elif w.isupper() and len(w) > 1:
            out.append(w)
        else:
            out.append(lw)
    if out and out[0][0].islower() and out[0] not in ACRONYMS.values():
        out[0] = out[0][0].upper() + out[0][1:]
    text = " ".join(out)
    for old, new in PHRASES:
        text = re.sub(old, new, text)
    return text


def entry_id(fq: str) -> str:
    short = fq[len("microsoft.graph."):] if fq.startswith("microsoft.graph.") else fq
    return ID_PREFIX + short.replace(".", "-")


# --------------------------------------------------------------------------- paths


def _descendants(schema) -> dict:
    """fq -> every type derived from it, at any depth."""
    direct = schema.derived()
    out = {}

    def walk(fq):
        if fq in out:
            return out[fq]
        acc = []
        for d in direct.get(fq, []):
            acc.append(d)
            acc.extend(walk(d))
        out[fq] = acc
        return acc

    for fq in schema.entities:
        walk(fq)
    return out


def find_paths(schema) -> dict:
    """fq -> {root: (path, item_path)}: the shortest containment path from each top-level root.

    path is what a caller lists or gets (a collection, or a single object); item_path is one object in it.
    Contained navigation properties declared on a derived type are followed with a cast segment, for example
    /deviceAppManagement/mobileApps/{id}/microsoft.graph.mobileLobApp/contentVersions."""
    desc = _descendants(schema)
    out: dict[str, dict] = {}
    for root, fq in schema.roots.items():
        if fq not in schema.entities:
            continue
        many = root in schema.entity_sets
        start = ("/" + root, "/" + root + ("/{id}" if many else ""))
        seen = {fq}
        out.setdefault(fq, {})[root] = start
        queue = deque([(fq, start[1])])
        while queue:
            t, item = queue.popleft()
            hops = []
            eff = schema.effective(t)
            for nav in sorted(eff["contained"]):
                hops.append((item + "/" + nav, nav in eff["many"], eff["navs"][nav]))
            for d in desc.get(t, []):   # contained navs declared on a derived type, reached through a cast
                e = schema.entities[d]
                for nav in sorted(e.get("contained", ())):
                    hops.append((f"{item}/{d}/{nav}", nav in e.get("many", ()), e["navs"][nav]))
            for path, is_many, target in hops:
                if target not in schema.entities:
                    continue
                if root not in out.setdefault(target, {}):
                    out[target][root] = (path, path + "/{id}" if is_many else path)
                if target not in seen:
                    seen.add(target)
                    queue.append((target, out[target][root][1]))
    return out


def _segments(path: str) -> int:
    return path.count("/")


def choose_paths(per_root: dict, area: str, limit: int = 4) -> list:
    """Order a type's paths: its own area's root first, then the shortest. Returns [(path, item_path)]."""
    ranked = sorted(per_root.items(), key=lambda kv: (kv[0] != area, _segments(kv[1][0]), kv[1][0].lower()))
    return [v for _, v in ranked[:limit]]


# --------------------------------------------------------------------------- entries


def _scan_block(fq, v1, beta) -> dict:
    e1 = v1.effective(fq)
    eb = beta.effective(fq) if beta else None
    props = sorted(e1["props"])
    navs = dict(sorted(e1["navs"].items()))
    return {
        "status": "v1.0",
        "props": props,
        "navs": navs,
        "betaOnlyProps": sorted((eb["props"] if eb else set()) - set(props)),
        "betaOnlyNavs": sorted(set(eb["navs"] if eb else {}) - set(navs)),
        "baseTypes": e1["chain"][1:],
    }


def _ops(schema, fq) -> dict:
    eff = schema.effective(fq)
    acts, funcs = set(), set()
    for t in eff["chain"]:
        for name, kind in schema.ops.get(t, {}).items():
            (acts if kind == "Action" else funcs).add(name)
    return {"actions": sorted(acts), "functions": sorted(funcs)}


def build_entries(v1, beta, types: dict) -> list:
    """One entry per v1.0 entity type that a root reaches, plus one per type that nothing reaches and that has
    no reachable ancestor. Every other type is a variant, folded into its nearest reachable ancestor.

    types: fq -> {"area", "status"} (from scan.coverage_types or coverage.json)."""
    paths = find_paths(v1)
    v1_types = [fq for fq in v1.entities if fq != "microsoft.graph.entity"]
    owner = {}   # fq -> the fq of the entry it belongs to
    for fq in v1_types:
        if fq in paths:
            owner[fq] = fq
            continue
        cur = v1.entities[fq]["base"]
        while cur and cur not in NOT_A_BASE and cur not in paths:
            cur = v1.entities.get(cur, {}).get("base")
        owner[fq] = cur if cur and cur not in NOT_A_BASE else fq
    variants: dict[str, list] = {}
    for fq, o in owner.items():
        if o != fq:
            variants.setdefault(o, []).append(fq)
    entries = []
    for fq in sorted(fq for fq, o in owner.items() if o == fq):
        area = (types.get(fq) or {}).get("area", "unrooted")
        chosen = choose_paths(paths.get(fq, {}), area)
        entries.append({
            "id": entry_id(fq),
            "label": label_for(fq),
            "entityType": fq,
            "tier": "generated",
            "area": area,
            "path": chosen[0][0] if chosen else None,
            "itemPath": chosen[0][1] if chosen else None,
            "altPaths": [p for p, _ in chosen[1:]],
            "variants": sorted(variants.get(fq, [])),
            "ops": _ops(v1, fq),
            "scan": _scan_block(fq, v1, beta),
        })
    # links: other entries this one points to through a relationship, or that point to it
    by_type = {}
    for e in entries:
        by_type[e["entityType"]] = e["id"]
        for v in e["variants"]:
            by_type[v] = e["id"]
    linked = {e["id"]: set() for e in entries}
    for e in entries:
        for t in e["scan"]["navs"].values():
            other = by_type.get(t)
            if other and other != e["id"]:
                linked[e["id"]].add(other)
                linked[other].add(e["id"])
    for e in entries:
        e["links"] = len(linked[e["id"]])
    return entries


# --------------------------------------------------------------------------- fetching (GitHub, read only)


def _get(url: str, accept: str = "application/json"):
    headers = {"Accept": accept, "User-Agent": "mgc-scanner/0.2"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
        return r.read()


def head_commit(repo: str) -> dict:
    """The commit the default branch points at, from git's public refs endpoint (not the rate-limited REST API).
    Reading files at this commit pins exactly what was used."""
    raw = _get(f"https://github.com/{repo}.git/info/refs?service=git-upload-pack", "*/*").decode("utf-8", "replace")
    m = re.search(r"([0-9a-f]{40}) HEAD\x00", raw)
    branch = re.search(r"symref=HEAD:refs/heads/([^\s\x00]+)", raw)
    if not m:
        raise ValueError(f"no HEAD in the refs of {repo}")
    return {"commit": m.group(1), "branch": branch.group(1) if branch else None}


def check_catalogue_shape(cat) -> None:
    """Raise CatalogueShapeError unless cat looks like {"permissions": {name: {"pathSets": [{"schemeKeys",
    "methods", "paths": {path: "least=..."|""}}]}}}."""
    if not isinstance(cat, dict) or not isinstance(cat.get("permissions"), dict) or not cat["permissions"]:
        raise CatalogueShapeError("no 'permissions' object")
    for name, p in cat["permissions"].items():
        sets = p.get("pathSets") if isinstance(p, dict) else None
        if not isinstance(sets, list):
            raise CatalogueShapeError(f"{name}: no 'pathSets' list")
        for ps in sets:
            if not (isinstance(ps, dict) and isinstance(ps.get("schemeKeys"), list)
                    and isinstance(ps.get("methods"), list) and isinstance(ps.get("paths"), dict)):
                raise CatalogueShapeError(f"{name}: a path set lacks schemeKeys, methods or paths")
            for v in ps["paths"].values():
                if not isinstance(v, str):
                    raise CatalogueShapeError(f"{name}: a path's value is not a string")


def fetch_catalogue() -> tuple[dict, dict]:
    """(catalogue, pin). Reads the file at the repository's current commit, so the pin names exactly what was used."""
    pin = head_commit(CATALOGUE_REPO)
    raw = _get(f"https://raw.githubusercontent.com/{CATALOGUE_REPO}/{pin['commit']}/{CATALOGUE_PATH}", "*/*")
    cat = json.loads(raw.decode("utf-8-sig"))
    check_catalogue_shape(cat)
    pin.update(repo=CATALOGUE_REPO, path=CATALOGUE_PATH)
    return cat, pin


def fetch_docs_index() -> tuple[list, dict]:
    """(resource page names without .md, pin) for the v1.0 resource pages on Microsoft Learn. Two REST API calls;
    set GITHUB_TOKEN to lift the anonymous limit of 60 calls an hour."""
    pin = head_commit(DOCS_REPO)
    parent, _, leaf = DOCS_DIR.rpartition("/")
    listing = json.loads(_get(f"https://api.github.com/repos/{DOCS_REPO}/contents/{parent}?ref={pin['commit']}"))
    sha = next(x["sha"] for x in listing if x["name"] == leaf and x["type"] == "dir")
    tree = json.loads(_get(f"https://api.github.com/repos/{DOCS_REPO}/git/trees/{sha}"))
    if tree.get("truncated"):
        raise ValueError("docs tree listing was truncated")
    names = sorted(x["path"][:-3] for x in tree["tree"] if x["type"] == "blob" and x["path"].endswith(".md"))
    pin.update(repo=DOCS_REPO, path=DOCS_DIR)
    return names, pin


# --------------------------------------------------------------------------- permissions and docs


def index_catalogue(cat: dict) -> dict:
    """lowercase path -> {scheme: {"least": set, "any": set}} for GET."""
    idx: dict[str, dict] = {}
    for name, p in cat["permissions"].items():
        if p.get("authorizationType", "oAuth2") != "oAuth2":
            continue
        for ps in p["pathSets"]:
            if "GET" not in ps["methods"]:
                continue
            for path, flag in ps["paths"].items():
                least = {s.strip() for s in flag[len("least="):].split(",")} if flag.startswith("least=") else set()
                slot = idx.setdefault(path.lower(), {})
                for scheme in ps["schemeKeys"]:
                    s = slot.setdefault(scheme, {"least": set(), "any": set()})
                    s["any"].add(name)
                    if scheme in least:
                        s["least"].add(name)
    return idx


def permissions_for(entry: dict, idx: dict) -> dict | None:
    """The permissions the catalogue marks least privileged for reading this entry, or None if the catalogue has
    no GET entry for any of its paths. Every name marked least is kept (in name order): the catalogue sometimes
    marks a read and a read-write permission both as least, and this code does not choose between them."""
    candidates = []
    for p in [entry.get("itemPath"), entry.get("path")] + [a + "/{id}" for a in entry.get("altPaths", [])] + entry.get("altPaths", []):
        if p and p.lower() not in candidates:
            candidates.append(p.lower())
    for p in candidates:
        slot = idx.get(p)
        if not slot:
            continue
        pick = lambda scheme: ", ".join(sorted((slot.get(scheme) or {}).get("least", ())))
        return {"delegated": pick("DelegatedWork"), "application": pick("Application"), "matchedPath": p}
    return None


def docs_for(fq: str, area: str, names: set) -> str | None:
    """The Learn resource page for a type, when the docs repository has exactly one that fits."""
    short = fq[len("microsoft.graph."):] if fq.startswith("microsoft.graph.") else fq
    exact = short.lower().replace(".", "-")
    intune = [n for n in names if re.fullmatch(r"intune-[a-z0-9]+-" + re.escape(exact), n)]
    if area in INTUNE_AREAS and len(intune) == 1:
        return LEARN_URL.format(intune[0])
    if exact in names:
        return LEARN_URL.format(exact)
    if len(intune) == 1:
        return LEARN_URL.format(intune[0])
    return None


def enrich(entries: list, catalogue: dict | None, docs_names: list | None) -> None:
    idx = index_catalogue(catalogue) if catalogue else None
    names = set(docs_names or [])
    for e in entries:
        if idx is not None:
            perms = permissions_for(e, idx)
            e["permissions"] = {"delegated": perms["delegated"], "application": perms["application"]} if perms else None
            e["permissionsPath"] = perms["matchedPath"] if perms else None
        if docs_names is not None:
            e["docs"] = docs_for(e["entityType"], e["area"], names)


# --------------------------------------------------------------------------- placement


def _match_path(pattern: str, path: str) -> bool:
    """Segment-wise prefix match, ignoring {id} segments; a segment may use * (fnmatch)."""
    want = [s for s in pattern.strip("/").split("/") if s]
    have = [s for s in path.strip("/").split("/") if s and s != "{id}"]
    if len(want) > len(have):
        return False
    return all(fnmatch.fnmatchcase(h, w) for w, h in zip(want, have))


def place(entry: dict, rules: list) -> tuple[str, str] | None:
    """(workload, subservice) for an entry: a 'type' rule first, then the longest matching 'path' rule, then a
    'namespace' rule, then an 'area' rule."""
    fq, path = entry["entityType"], entry.get("path") or ""
    for r in rules:
        if r.get("type") == fq:
            return tuple(r["to"].split("/", 1))
    best = None
    for r in rules:
        if "path" in r and path and _match_path(r["path"], path):
            n = len([s for s in r["path"].split("/") if s])
            if not best or n > best[0]:
                best = (n, r)
    if best:
        return tuple(best[1]["to"].split("/", 1))
    ns = fq.rpartition(".")[0]
    for r in rules:
        if r.get("namespace") == ns:
            return tuple(r["to"].split("/", 1))
    for r in rules:
        if r.get("area") == entry.get("area"):
            return tuple(r["to"].split("/", 1))
    return None


def rule_problems(placement: dict, workloads: list) -> list:
    subs = {w["id"]: {s["id"] for s in w.get("subservices") or []} for w in workloads}
    out = []
    for r in placement.get("rules", []):
        to = r.get("to", "")
        w, _, s = to.partition("/")
        if w not in subs or s not in subs[w]:
            out.append(f"placement rule {json.dumps(r)} points to '{to}', which is not a workload/sub-service")
    return out


def merge(curated_nodes: list, entries: list, placement: dict, workloads: list) -> tuple[list, dict]:
    """Generated nodes for the areas placement.json lists, and a report for the build rule.

    A curated node overrides the generated entry for the same type (its entityType or covers[]): the entry is
    dropped and its variants move to the curated node. Returns (nodes_to_add, report) where report has
    'areas', 'unplaced' (entry types no rule places) and 'rules' (rules that point nowhere)."""
    areas = set(placement.get("areas", []))
    rules = placement.get("rules", [])
    curated_types = set()
    for n in curated_nodes:
        if n.get("entityType"):
            curated_types.add(n["entityType"])
        curated_types.update(n.get("covers") or [])
    by_curated = {n["entityType"]: n for n in curated_nodes if n.get("entityType")}
    out, unplaced, inherited = [], [], {}
    for e in entries:
        if e["area"] not in areas:
            continue
        variants = [v for v in e.get("variants", []) if v not in curated_types]
        if e["entityType"] in curated_types:
            if e["entityType"] in by_curated and variants:
                inherited.setdefault(by_curated[e["entityType"]]["id"], []).extend(variants)
            continue
        where = place(e, rules)
        if not where:
            unplaced.append(e["entityType"])
            continue
        n = {k: v for k, v in e.items() if k not in ("area",)}
        n["variants"] = variants
        n["workload"], n["subservice"] = where
        n["area"] = e["area"]
        out.append(n)
    report = {"areas": sorted(areas), "unplaced": sorted(unplaced), "rules": rule_problems(placement, workloads),
              "inheritedVariants": inherited}
    return out, report
