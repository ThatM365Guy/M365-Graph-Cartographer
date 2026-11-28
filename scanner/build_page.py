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


def render(template: str, graph_map: dict, allow_unsorted: bool = False, scripts: dict | None = None) -> str:
    if "nodes" in graph_map:
        validate(graph_map, allow_unsorted)
    data = {k: v for k, v in graph_map.items() if k != "state"}
    if scripts:
        data["scripts"] = scripts
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # keep the JSON from closing the <script> element early
    payload = payload.replace("</", "<\\/").replace("<!--", "<\\!--")
    if MARKER not in template:
        raise ValueError(f"template is missing the data marker {MARKER}")
    return template.replace(MARKER, payload, 1)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data/graph-map.json")
    ap.add_argument("--template", default="web/template.html")
    ap.add_argument("--out", default="dist/index.html")
    ap.add_argument("--scripts", default="scripts/scenarios", help="folder of scenario scripts to embed (missing is fine)")
    ap.add_argument("--allow-unsorted", action="store_true",
                    help="build even if some nodes have no sub-service (shown under 'Unsorted')")
    a = ap.parse_args(argv)
    with open(a.template, encoding="utf-8") as f:
        template = f.read()
    with open(a.data, encoding="utf-8") as f:
        graph_map = json.load(f)
    try:
        html = render(template, graph_map, a.allow_unsorted, load_scripts(a.scripts))
    except BuildError as e:
        raise SystemExit(f"build_page: {e}")
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(html)
    unsorted = subservice_problems(graph_map)[1]
    print(f"wrote {a.out} ({len(html) // 1024} KB)" + (f"; unsorted: {', '.join(unsorted)}" if unsorted else ""))


if __name__ == "__main__":
    main()
