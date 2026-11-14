"""
Build the single-file page: web/template.html + graph-map.json -> dist/index.html.

The data is embedded in the page, so it works anywhere (static website,
SharePoint page, Claude artifact, a file opened from disk) with no API calls.

Usage:
  python scanner/build_page.py --data data/graph-map.json --template web/template.html --out dist/index.html
"""
import argparse
import json
import os

MARKER = "/*__GRAPH_DATA__*/null"


def render(template: str, graph_map: dict) -> str:
    data = {k: v for k, v in graph_map.items() if k != "state"}
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
    a = ap.parse_args(argv)
    with open(a.template, encoding="utf-8") as f:
        template = f.read()
    with open(a.data, encoding="utf-8") as f:
        graph_map = json.load(f)
    html = render(template, graph_map)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"wrote {a.out} ({len(html) // 1024} KB)")


if __name__ == "__main__":
    main()
