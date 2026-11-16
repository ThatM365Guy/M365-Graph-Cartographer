"""
Azure Function (Python v2 programming model) that keeps M365 Graph Cartographer (MGC) up to date.

Timer trigger (default: Mondays 05:30 UTC, set SCAN_SCHEDULE to change it) and an
HTTP trigger for on-demand runs both:

  1. read curated.json (bundled with the deployment, so edits go through Git)
  2. read the previous graph-map.json from blob storage
  3. scan Microsoft Graph v1.0 and beta $metadata (anonymous, no Graph permissions needed)
  4. optionally check permission names (CHECK_PERMISSIONS=true; the managed identity
     then needs the Graph application permission Application.Read.All)
  5. write graph-map.json, changelog.json and index.html to the static website container

App settings:
  STORAGE_ACCOUNT_URL   https://<account>.blob.core.windows.net
  WEB_CONTAINER         $web (default; the storage account's static website container)
  SCAN_SCHEDULE         NCRONTAB, for example "0 30 5 * * 1"
  CHECK_PERMISSIONS     true | false (default false)
  AZURE_CLIENT_ID       client ID of a user-assigned managed identity (omit for system-assigned)
"""
import json
import logging
import os
import pathlib
import sys

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE / "scanner"))

import build_page  # noqa: E402
import scan  # noqa: E402

app = func.FunctionApp()
log = logging.getLogger("mgc")


def _container():
    cred = DefaultAzureCredential()
    svc = BlobServiceClient(os.environ["STORAGE_ACCOUNT_URL"], credential=cred)
    return svc.get_container_client(os.environ.get("WEB_CONTAINER", "$web")), cred


def _read_json(container, name, default=None):
    blob = container.get_blob_client(name)
    if not blob.exists():
        return default
    return json.loads(blob.download_blob().readall())


def _write(container, name, text, content_type):
    container.get_blob_client(name).upload_blob(
        text.encode("utf-8"), overwrite=True,
        content_settings=ContentSettings(content_type=content_type, cache_control="no-cache"))


def run_scan(force_permissions: bool = False) -> dict:
    container, cred = _container()
    curated = json.loads((HERE / "data" / "curated.json").read_text(encoding="utf-8"))
    template = (HERE / "web" / "template.html").read_text(encoding="utf-8")
    previous = _read_json(container, "graph-map.json")

    token = None
    if force_permissions or os.environ.get("CHECK_PERMISSIONS", "false").lower() == "true":
        token = cred.get_token("https://graph.microsoft.com/.default").token

    coverage: dict = {}
    graph_map, changes = scan.build_map(curated, previous, token=token, scan=True,
                                        prev_coverage=_read_json(container, "coverage.json"), coverage_out=coverage)
    changelog = changes + (_read_json(container, "changelog.json", []) or [])

    _write(container, "graph-map.json", json.dumps(graph_map, ensure_ascii=False), "application/json")
    _write(container, "changelog.json", json.dumps(changelog[: scan.CHANGELOG_KEEP], ensure_ascii=False, indent=1),
           "application/json")
    if coverage:
        _write(container, "coverage.json", json.dumps(coverage, ensure_ascii=False), "application/json")
    _write(container, "index.html", build_page.render(template, graph_map), "text/html; charset=utf-8")

    summary = {"changes": len(changes), "scan": graph_map["meta"].get("scan"),
               "notFound": [n["id"] for n in graph_map["nodes"] if (n.get("scan") or {}).get("status") == "not found"]}
    log.info("MGC scan complete: %s", summary)
    return summary


@app.timer_trigger(schedule="%SCAN_SCHEDULE%", arg_name="timer", run_on_startup=False, use_monitor=True)
def scheduled_scan(timer: func.TimerRequest) -> None:
    if timer.past_due:
        log.warning("Timer is past due; running now.")
    run_scan()


@app.route(route="scan", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def manual_scan(req: func.HttpRequest) -> func.HttpResponse:
    try:
        summary = run_scan(force_permissions=req.params.get("permissions") == "true")
        return func.HttpResponse(json.dumps(summary), mimetype="application/json")
    except Exception as exc:  # surface the reason to the caller; details are in App Insights
        log.exception("Scan failed")
        return func.HttpResponse(json.dumps({"error": str(exc)}), status_code=500, mimetype="application/json")
