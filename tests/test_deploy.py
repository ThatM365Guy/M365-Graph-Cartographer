"""Checks on the deployment wrappers: the Azure Function package and the GitHub Actions workflow."""
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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


if __name__ == "__main__":
    unittest.main()
