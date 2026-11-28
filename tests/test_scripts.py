"""Phase 7: read-only PowerShell scripts for every scenario (scripts/scenarios/<scenario-id>.ps1) and the
PowerShell shown on each scenario step (steps[].ps in data/curated.json).

The guard tests here need no PowerShell, so they run anywhere. The SDK checks (Find-MgGraphCommand, parameters,
PSScriptAnalyzer) run through tests/check_scripts.ps1 when PowerShell 7 and Microsoft.Graph.Authentication are
installed, and are skipped otherwise."""
import json
import os
import re
import shutil
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scanner"))
import build_page  # noqa: E402

SCRIPTS = os.path.join(ROOT, "scripts", "scenarios")
LIVE = "https://thatm365guy.github.io/M365-Graph-Cartographer/#scenario-"
POST_LABEL = "# read-only, uses POST"

with open(os.path.join(ROOT, "scripts", "allowlist.json"), encoding="utf-8") as f:
    ALLOW = json.load(f)
with open(os.path.join(ROOT, "data", "curated.json"), encoding="utf-8") as f:
    CURATED = json.load(f)
NODES = {n["id"]: n for n in CURATED["nodes"]}

# Cmdlets from Microsoft.Graph.Authentication that read or connect, and nothing else.
AUTH_OK = {"Connect-MgGraph", "Get-MgContext", "Invoke-MgGraphRequest"}
# Anything that could send data somewhere other than Microsoft Graph, or run other code.
FORBIDDEN = re.compile(r"\b(Invoke-RestMethod|Invoke-WebRequest|irm|iwr|curl|wget|Send-MailMessage|Start-Process|"
                       r"Invoke-Expression|iex|Net\.WebClient|HttpClient|Start-BitsTransfer|Invoke-Command|"
                       r"Set-Content|Out-File|Add-Content|Remove-Item|Disconnect-MgGraph|"
                       # an alias of Invoke-MgGraphRequest that the -Method check below would not see
                       # (the other alias, Invoke-MgRestMethod, is caught as a non-Get Mg cmdlet)
                       r"Invoke-GraphRequest)\b", re.I)
WRITE_VERBS = ("New", "Set", "Update", "Remove", "Add")


def code_only(text):
    """Drops comment blocks and full-line comments so the guard reads code, not help text."""
    text = re.sub(r"<#.*?#>", "", text, flags=re.S)
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def guard_problems(text, where):
    """The read-only guard: only Get-Mg* cmdlets and GET requests, plus the allow list, each labelled."""
    out = []
    code = code_only(text)
    for i, line in enumerate(code.splitlines(), 1):
        for m in re.finditer(r"\b([A-Za-z]+)-(Mg[A-Za-z0-9]+)\b", line):
            name = m.group(0)
            if name in AUTH_OK or m.group(1) == "Get":
                continue
            if name in ALLOW["cmdlets"]:
                if POST_LABEL not in line:
                    out.append(f"{where}:{i}: {name} needs the comment '{POST_LABEL}' on the same line")
                continue
            kind = "a write cmdlet" if m.group(1) in WRITE_VERBS else "not a Get- cmdlet or on the allow list"
            out.append(f"{where}:{i}: {name} is {kind}")
        if "Invoke-MgGraphRequest" in line:
            meth = re.search(r"-Method\s+['\"]?([A-Za-z]+)", line)
            if not meth:
                out.append(f"{where}:{i}: Invoke-MgGraphRequest needs -Method on the same line")
            elif meth.group(1).upper() == "POST":
                if POST_LABEL not in line or not any(u in line for u in ALLOW["uris"]):
                    out.append(f"{where}:{i}: POST is only allowed to {', '.join(ALLOW['uris'])}, labelled '{POST_LABEL}'")
            elif meth.group(1).upper() != "GET":
                out.append(f"{where}:{i}: Invoke-MgGraphRequest -Method {meth.group(1)} is not read-only")
        f = FORBIDDEN.search(line)
        if f:
            out.append(f"{where}:{i}: {f.group(0)} is not allowed in a read-only scenario script")
        for u in re.findall(r"https?://[^\s'\"`)]+", line):
            if not re.match(r"https://graph\.microsoft\.com(/|$)", u):
                out.append(f"{where}:{i}: {u} is not Microsoft Graph")
    return out


def script_path(sid):
    return os.path.join(SCRIPTS, f"{sid}.ps1")


def read(sid):
    with open(script_path(sid), encoding="utf-8") as f:
        return f.read()


def connect_scopes(text):
    m = re.search(r"\$Scopes\s*=\s*@\(([^)]*)\)", text)
    return re.findall(r"'([^']+)'", m.group(1)) if m else None


class ScriptFiles(unittest.TestCase):
    def test_one_script_per_scenario(self):
        ids = {s["id"] for s in CURATED["scenarios"]}
        files = {f[:-4] for f in os.listdir(SCRIPTS) if f.endswith(".ps1")}
        self.assertEqual(sorted(ids - files), [], "scenarios without a script")
        self.assertEqual(sorted(files - ids), [], "scripts without a scenario")

    def test_headers(self):
        need = ["Purpose:", "Scopes (delegated, read-only):", "Entra roles:", "Licence:", "What it doesn't do:",
                "Tested:", ".PARAMETER OutputFolder", ".EXAMPLE"]
        for s in CURATED["scenarios"]:
            text = read(s["id"])
            head = text.split("#>", 1)[0]
            for n in need:
                self.assertIn(n, head, f"{s['id']}: header lacks '{n}'")
            self.assertIn(LIVE + s["id"], head, f"{s['id']}: header lacks its live scenario link")
            self.assertTrue(text.startswith("#Requires -Version 7"), f"{s['id']}: needs '#Requires -Version 7.0' first")
            self.assertRegex(head, r"Tested: (not yet|\d{4}-\d{2}-\d{2})", f"{s['id']}: 'Tested:' needs 'not yet' or a date")

    def test_read_only_guard(self):
        problems = []
        for f in sorted(os.listdir(SCRIPTS)):
            if f.endswith(".ps1"):
                with open(os.path.join(SCRIPTS, f), encoding="utf-8") as fh:
                    problems += guard_problems(fh.read(), f)
        self.assertEqual(problems, [])

    def test_guard_catches_writes(self):
        bad = ("Remove-MgUser -UserId $id\nNew-MgGroup @p\nUpdate-MgApplication -ApplicationId $a\n"
               "Set-MgUserLicense -UserId $u\nAdd-MgGroupMember -GroupId $g\n"
               "Invoke-MgGraphRequest -Method PATCH -Uri '/v1.0/users/x'\n"
               "Invoke-MgGraphRequest -Method POST -Uri '/v1.0/users/x/revokeSignInSessions'\n"
               "Start-MgSecurityHuntingQuery -BodyParameter $b\n"
               "Invoke-RestMethod https://example.com -Body $data\n"
               "Invoke-GraphRequest -Method DELETE -Uri '/v1.0/users/x'\n"
               "Invoke-MgRestMethod -Method DELETE -Uri '/v1.0/users/x'\n"
               "# Remove-MgUser in a comment is fine\n")
        found = guard_problems(bad, "x")
        self.assertEqual(len(found), 12, found)
        self.assertTrue(any("Invoke-GraphRequest" in f for f in found))

    def test_scopes_are_read_only_and_real(self):
        names = set(build_page_state().get("permissionNames") or [])
        for s in CURATED["scenarios"]:
            scopes = connect_scopes(read(s["id"]))
            self.assertTrue(scopes, f"{s['id']}: needs a $Scopes = @(...) list for Connect-MgGraph")
            for sc in scopes:
                self.assertRegex(sc, r"\.Read(Basic)?(\.|$)", f"{s['id']}: {sc} is not a read scope")
                self.assertNotIn("ReadWrite", sc, f"{s['id']}: {sc}")
                if names:
                    self.assertIn(sc, names, f"{s['id']}: {sc} is not a Microsoft Graph permission name")
            self.assertIn("Connect-MgGraph -Scopes $Scopes", read(s["id"]), s["id"])

    def test_names_and_addresses_in_filters_are_quote_escaped(self):
        """A UPN or address can hold an apostrophe (o'brien@contoso.com), which ends an OData string early."""
        raw = re.compile(r"(userPrincipalName|senderAddress|recipientAddress|mail)\s+(eq|ne)\s+'\$(?!\(ConvertTo-ODataLiteral )", re.I)
        bad = []
        for s in CURATED["scenarios"]:
            for i, line in enumerate(code_only(read(s["id"])).splitlines(), 1):
                if raw.search(line):
                    bad.append(f"{s['id']}:{i}: use ConvertTo-ODataLiteral for the value")
        self.assertEqual(bad, [])
        self.assertTrue(raw.search("-Filter \"userPrincipalName eq '$($u.UserPrincipalName)'\""))

    def test_recipient_lists_are_read_one_by_one(self):
        """$list.EmailAddress.Address returns System.Array's Address method once a list has two recipients."""
        rx = re.compile(r"(ForwardTo|RedirectTo|ForwardAsAttachmentTo|Recipients)\.EmailAddress\.Address", re.I)
        bad = [f"{s['id']}:{i}" for s in CURATED["scenarios"]
               for i, line in enumerate(code_only(read(s["id"])).splitlines(), 1) if rx.search(line)]
        self.assertEqual(bad, [], "use Get-RecipientAddress")

    def test_csv_output_only_to_output_folder(self):
        for s in CURATED["scenarios"]:
            text = code_only(read(s["id"]))
            self.assertIn("Export-Csv", text, f"{s['id']}: writes no CSV")
            self.assertNotRegex(text, r"Export-Csv\s+-Path\s+['\"]?[A-Za-z]:", f"{s['id']}: hard-coded output path")


def build_page_state():
    p = os.path.join(ROOT, "data", "graph-map.json")
    if not os.path.exists(p):
        return {}
    with open(p, encoding="utf-8") as f:
        return json.load(f).get("state") or {}


class StepSnippets(unittest.TestCase):
    def test_snippets_are_read_only(self):
        problems = []
        for s in CURATED["scenarios"]:
            for i, st in enumerate(s["steps"], 1):
                if "ps" in st:
                    problems += guard_problems(st["ps"], f"{s['id']} step {i}")
        self.assertEqual(problems, [])

    def test_every_read_step_has_powershell(self):
        """A step gets PowerShell unless it is outside Graph or changes data (psNote says which)."""
        missing = []
        for s in CURATED["scenarios"]:
            for i, st in enumerate(s["steps"], 1):
                if "ps" not in st and not st.get("psNote") and NODES[st["node"]].get("kind") != "gap":
                    missing.append(f"{s['id']} step {i}")
        self.assertEqual(missing, [])


class Embedding(unittest.TestCase):
    def test_build_embeds_scripts(self):
        sc = build_page.load_scripts(SCRIPTS)
        ids = {s["id"] for s in CURATED["scenarios"]}
        self.assertEqual(set(sc), ids)
        for sid, v in sc.items():
            self.assertTrue(v["text"].startswith("#Requires"))
            self.assertTrue(v["tested"] == "" or re.fullmatch(r"\d{4}-\d{2}-\d{2}", v["tested"]), sid)

    def test_missing_folder_is_fine(self):
        self.assertEqual(build_page.load_scripts(os.path.join(ROOT, "no-such-folder")), {})


def pwsh_ready():
    exe = shutil.which("pwsh")
    if not exe:
        return None
    r = subprocess.run([exe, "-NoProfile", "-Command", "if (Get-Module -ListAvailable Microsoft.Graph.Authentication) { 'yes' }"],
                       capture_output=True, text=True, timeout=120)
    return exe if "yes" in r.stdout else None


@unittest.skipUnless(os.environ.get("MGC_SKIP_PWSH") != "1" and pwsh_ready(),
                     "PowerShell 7 with Microsoft.Graph.Authentication is not installed")
class SdkChecks(unittest.TestCase):
    def test_cmdlets_parameters_and_analyser(self):
        r = subprocess.run([pwsh_ready(), "-NoProfile", "-File", os.path.join(ROOT, "tests", "check_scripts.ps1"), "-Root", ROOT],
                           capture_output=True, text=True, timeout=1800)
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        out = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(out["errors"], [], "\n".join(out["errors"]))
        self.assertGreater(out["checked"], 0)
        if out["analyzer"] != "ran":
            print("\n  note: PSScriptAnalyzer is not installed, so the analyser check was skipped", file=sys.stderr)


if __name__ == "__main__":
    unittest.main()
