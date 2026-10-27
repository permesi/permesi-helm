#!/usr/bin/env python3
"""Exercise the actual release version gate with isolated chart metadata."""
import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/check-chart-versions.py"


class ChartVersionTests(unittest.TestCase):
    def gate(self, mutate=None, expected="0.4.6"):
        charts = {name: {"name": name, "version": "0.4.6", "appVersion": "0.4.3"}
                  for name in ("permesi", "genesis", "web", "permesi-stack")}
        charts["permesi-stack"]["dependencies"] = [
            {"name": name, "version": "0.4.6"} for name in ("permesi", "genesis", "web")]
        charts["permesi-stack"]["dependencies"].append({"name": "permesi-quickstart", "version": "0.1.0"})
        if mutate:
            mutate(charts)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, chart in charts.items():
                path = root / "charts" / name / "Chart.yaml"
                path.parent.mkdir(parents=True)
                path.write_text(yaml.safe_dump(chart))
            before = {str(p): p.read_bytes() for p in root.rglob("Chart.yaml")}
            result = subprocess.run([sys.executable, str(SCRIPT), "--root", directory,
                                     "--expected", expected], text=True, capture_output=True)
            self.assertEqual(before, {str(p): p.read_bytes() for p in root.rglob("Chart.yaml")})
            return result

    def test_chart_only_versions_allow_independent_application_and_helper_versions(self):
        self.assertEqual(self.gate().returncode, 0)

    def test_current_web_version_mismatch_is_rejected(self):
        result = self.gate(lambda charts: charts["web"].update(version="0.4.4"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("chart web has version 0.4.4", result.stderr)

    def test_stale_missing_or_duplicate_dependency_is_rejected(self):
        def duplicate(charts):
            dependencies = charts["permesi-stack"]["dependencies"]
            dependencies.append(copy.deepcopy(dependencies[0]))
        for mutate in (lambda c: c["permesi-stack"]["dependencies"][0].update(version="0.4.5"),
                       lambda c: c["permesi-stack"].update(dependencies=[]), duplicate):
            with self.subTest(mutation=mutate):
                self.assertNotEqual(self.gate(mutate).returncode, 0)

    def test_release_event_version_must_match_checked_out_charts(self):
        self.assertNotEqual(self.gate(expected="0.4.7").returncode, 0)


if __name__ == "__main__":
    unittest.main()
