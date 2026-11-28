"""Checks on the deployment wrappers: the Azure Function package and the GitHub Actions workflow."""
import json
import os
import pathlib
import re
import sys
import types
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scanner"))
import build_page  # noqa: E402
import scan  # noqa: E402

REAL_BUILD_MAP = scan.build_map


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def local_imports(module):
    """Names of the scanner modules that scanner/<module>.py imports."""
    here = {f[:-3] for f in os.listdir(os.path.join(ROOT, "scanner")) if f.endswith(".py")}
    found = set(re.findall(r"^\s*import (\w+)", read("scanner", module + ".py"), re.M))
    found |= set(re.findall(r"^\s*from (\w+) import", read("scanner", module + ".py"), re.M))
    return found & here


class FunctionPackage(unittest.TestCase):
    def test_package_scripts_copy_every_scanner_module_the_function_imports(self):
        needed = {"scan", "build_page"} | local_imports("scan") | local_imports("build_page")
        self.assertIn("generate", needed)
        for script, sep in (("package.sh", "/"), ("package.ps1", "\\")):
            text = read("function_app", script)
            if f"..{sep}scanner{sep}*.py" in text:
                continue
            missing = [m for m in needed if f"{m}.py" not in text]
            self.assertEqual(missing, [], f"{script} doesn't copy {missing}")


class Workflow(unittest.TestCase):
    def setUp(self):
        self.yml = read(".github", "workflows", "scan.yml")

    def test_bot_commits_every_file_the_scan_writes(self):
        add = re.search(r"git add ([^\n]+)", self.yml).group(1).split()
        for f in ("data/graph-map.json", "data/changelog.json", "data/coverage.json", "data/generated.json"):
            self.assertIn(f, add)


def import_function_app():
    """function_app.py with the azure-* packages stubbed (they are only installed in the Function)."""
    stubs = {name: types.ModuleType(name) for name in ("azure", "azure.functions", "azure.identity", "azure.storage",
                                                        "azure.storage.blob")}
    stubs["azure.functions"].__dict__.update(FunctionApp=mock.MagicMock, AuthLevel=mock.MagicMock(),
                                             HttpResponse=mock.MagicMock, TimerRequest=object, HttpRequest=object)
    stubs["azure.identity"].DefaultAzureCredential = mock.MagicMock
    stubs["azure.storage.blob"].__dict__.update(BlobServiceClient=mock.MagicMock, ContentSettings=mock.MagicMock)
    with mock.patch.dict(sys.modules, stubs):
        sys.modules.pop("function_app", None)
        sys.path.insert(0, os.path.join(ROOT, "function_app"))
        try:
            import function_app
        finally:
            sys.path.remove(os.path.join(ROOT, "function_app"))
    return function_app


class FakeContainer:
    def __init__(self):
        self.blobs = {}

    def get_blob_client(self, name):
        c = self
        blob = mock.MagicMock()
        blob.exists.side_effect = lambda: name in c.blobs
        blob.download_blob.side_effect = lambda: mock.MagicMock(readall=lambda: c.blobs[name])
        blob.upload_blob.side_effect = lambda data, **kw: c.blobs.__setitem__(name, data)
        return blob


class FunctionScan(unittest.TestCase):
    """run_scan() places the generated tier like the Actions run, and checks the build before it writes anything."""

    def run_with(self, fake_build_map):
        fa = import_function_app()
        box = FakeContainer()
        with mock.patch.object(fa, "HERE", pathlib.Path(ROOT)),                 mock.patch.object(fa, "_container", lambda: (box, None)),                 mock.patch.object(fa.scan, "build_map", fake_build_map):
            try:
                return fa.run_scan(), box
            except build_page.BuildError as e:
                return e, box

    def test_scan_places_generated_entries_and_writes_every_file(self):
        seen = {}

        def fake(curated, previous, **kw):   # the real merge, without fetching $metadata
            seen.update(kw)
            return REAL_BUILD_MAP(curated, previous, scan=False, prev_generated=kw["prev_generated"],
                                  placement=kw["placement"], generated_out=kw["generated_out"],
                                  coverage_out=kw["coverage_out"])

        summary, box = self.run_with(fake)
        self.assertTrue(seen["placement"]["rules"])
        self.assertTrue(seen["prev_generated"]["entries"])      # bundled copy on the first run
        self.assertTrue(seen["fetch_github"])
        self.assertEqual(sorted(box.blobs), ["changelog.json", "generated.json", "graph-map.json", "index.html"])
        page = json.loads(box.blobs["graph-map.json"])
        self.assertTrue(any(n.get("tier") == "generated" for n in page["nodes"]))
        self.assertEqual(summary["changes"], 0)

    def test_failed_build_check_writes_nothing(self):
        def fake(curated, previous, **kw):   # no placement: curated nodes only, so sub-services are empty
            return REAL_BUILD_MAP(curated, previous, scan=False)

        err, box = self.run_with(fake)
        self.assertIsInstance(err, build_page.BuildError)
        self.assertEqual(box.blobs, {})


if __name__ == "__main__":
    unittest.main()
