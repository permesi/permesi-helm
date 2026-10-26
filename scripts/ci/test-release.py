#!/usr/bin/env python3
"""Release contracts: python3 scripts/ci/test-release.py (requires jq, git, PyYAML).

Runs the actual event parser against JSON fixtures and the bump command in an
isolated TemporaryDirectory worktree. Never changes the caller's values.
The worktree is removed even when an assertion fails.
"""
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
SERVICES = ("permesi", "genesis", "web")
DIGESTS = {svc: "sha256:" + c * 64 for svc, c in zip(SERVICES, "abc")}
FIXTURES = ROOT / "scripts/ci/release-events"


def run(*args, cwd=ROOT, env=None):
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)


def load(path):
    return yaml.safe_load(path.read_text())


class EventTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="dig-event-", dir="/var/tmp")
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.sentinel = self.scratch / "injection-executed"

    def tearDown(self):
        self.assertFalse(self.sentinel.exists(), "payload was evaluated as shell")

    def parse(self, event, kind="repository_dispatch", succeeds=True):
        with tempfile.TemporaryDirectory(prefix="parse-", dir=self.scratch) as tmp:
            path = Path(tmp) / "event.json"
            output = Path(tmp) / "output"
            path.write_text(json.dumps(event).replace("__INJECTION_SENTINEL__", str(self.sentinel)))
            result = run(
                "bash", str(ROOT / "scripts/ci/release-event.sh"),
                env={**os.environ, "GITHUB_EVENT_NAME": kind,
                     "GITHUB_EVENT_PATH": str(path), "GITHUB_OUTPUT": str(output),
                     "GITHUB_ACTOR": "release-bot[bot]", "GITHUB_SHA": "d" * 40,
                     "GITHUB_REF": "refs/heads/main"},
            )
            if succeeds:
                self.assertEqual(result.returncode, 0, result.stderr)
                return dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertFalse(output.exists(), "invalid input must not write any outputs")
            return result.stderr

    def test_missing_jq_reports_dependency_without_writing_metadata(self):
        output = self.scratch / "output"
        result = run(
            shutil.which("bash"), str(ROOT / "scripts/ci/release-event.sh"),
            env={**os.environ, "PATH": str(self.scratch),
                 "GITHUB_EVENT_NAME": "repository_dispatch",
                 "GITHUB_EVENT_PATH": str(FIXTURES / "valid.json"),
                 "GITHUB_OUTPUT": str(output)},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required dependency 'jq'", result.stderr)
        self.assertFalse(output.exists())

    def valid(self):
        return json.loads((FIXTURES / "valid.json").read_text())

    def test_dispatch_records_all_image_and_source_identities(self):
        event = self.valid()
        meta = self.parse(event)
        self.assertEqual(meta["mode"], "digest")
        self.assertEqual(meta["version"], "0.4.3")
        for svc in SERVICES:
            self.assertEqual(meta[svc + "_digest"], DIGESTS[svc])
        for key in ("source_repo", "source_sha", "source_tag"):
            self.assertEqual(meta[key], event["client_payload"][key])

    def test_bad_json_fixtures_do_not_execute_or_emit_metadata(self):
        self.assertFalse(self.sentinel.exists(), "test sentinel already exists")
        for fixture in ("partial", "malformed", "injection"):
            with self.subTest(fixture=fixture):
                self.parse(json.loads((FIXTURES / (fixture + ".json")).read_text()), succeeds=False)

    def test_dispatch_checks_repositories_tags_and_source(self):
        cases = (
            ("source_repo", "attacker/permesi"),
            ("source_sha", "not-a-commit"),
            ("source_tag", "v0.4.2"),
            ("version", f"$(touch {self.sentinel})"),
        )
        for key, value in cases:
            with self.subTest(key=key):
                event = self.valid()
                event["client_payload"][key] = value
                self.parse(event, succeeds=False)
        for svc in SERVICES:
            for key, value in (("repository", "ghcr.io/attacker/" + svc),
                               ("tag", "v0.4.3"), ("tag", "0.4.4"),
                               ("digest", 42), ("digest", DIGESTS[svc] + "\n"),
                               ("digest", DIGESTS[svc] + "\u0000")):
                with self.subTest(svc=svc, key=key, value=value):
                    event = self.valid()
                    event["client_payload"]["images"][svc][key] = value
                    self.parse(event, succeeds=False)

    def test_dispatch_tag_only_needs_explicit_acknowledgement(self):
        event = self.valid()
        for svc in SERVICES:
            event["client_payload"]["images"][svc]["digest"] = ""
        self.parse(event, succeeds=False)
        event["client_payload"]["tag_only"] = True
        self.assertEqual(self.parse(event)["mode"], "tag-only")
        del event["client_payload"]["images"]["web"]["digest"]
        self.parse(event, succeeds=False)

    def test_dispatch_acknowledgement_requires_json_boolean(self):
        for value in ("true", "false", None, 0, 1, {}, []):
            with self.subTest(value=value):
                event = self.valid()
                for svc in SERVICES:
                    event["client_payload"]["images"][svc]["digest"] = ""
                event["client_payload"]["tag_only"] = value
                self.parse(event, succeeds=False)

    def test_manual_digest_or_explicit_tag_only(self):
        event = {"inputs": {"version": "v0.4.3", "chart_version": "0.4.5",
                            "tag_only": False,
                            **{svc + "_digest": DIGESTS[svc] for svc in SERVICES}}}
        meta = self.parse(event, "workflow_dispatch")
        self.assertEqual(meta["chart_version"], "0.4.5")
        self.assertEqual(meta["source_repo"], "manual")
        self.assertEqual(meta["source_sha"], "d" * 40)
        event["inputs"]["tag_only"] = True
        self.parse(event, "workflow_dispatch", succeeds=False)
        event["inputs"] = {"version": "0.4.3"}
        self.parse(event, "workflow_dispatch", succeeds=False)
        event["inputs"]["tag_only"] = "true"
        self.assertEqual(self.parse(event, "workflow_dispatch")["mode"], "tag-only")
        event["inputs"]["web_digest"] = DIGESTS["web"]
        self.parse(event, "workflow_dispatch", succeeds=False)


class BumpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory(prefix="dig-bump-", dir="/var/tmp")
        cls.addClassCleanup(scratch.cleanup)
        cls.worktree = Path(scratch.name) / "worktree"
        cls.sentinel = Path(scratch.name) / "injection-executed"
        result = run("git", "worktree", "add", "--detach", str(cls.worktree), "HEAD")
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.addClassCleanup(cls.remove_worktree)

        # Fixed release fixtures remain valid after the real charts advance.
        for svc in (*SERVICES, "permesi-stack"):
            path = cls.worktree / "charts" / svc / "Chart.yaml"
            text = path.read_text()
            text = re.sub(r"^version:.*$", "version: 0.4.4", text, flags=re.M)
            text = re.sub(r"^appVersion:.*$", "appVersion: 0.4.3", text, flags=re.M)
            text = re.sub(r"(^  - name: (?:permesi|genesis|web)\n)    version:.*$",
                          r"\g<1>    version: 0.4.4", text, flags=re.M)
            path.write_text(text)
        files = run("git", "ls-files", cwd=cls.worktree)
        if files.returncode:
            raise RuntimeError(files.stderr)
        cls.baseline = {f: (cls.worktree / f).read_bytes() for f in files.stdout.splitlines()}

    @classmethod
    def remove_worktree(cls):
        result = run("git", "worktree", "remove", "--force", str(cls.worktree))
        if result.returncode:
            raise RuntimeError(result.stderr)

    def setUp(self):
        for f, data in self.baseline.items():
            (self.worktree / f).write_bytes(data)

    def tearDown(self):
        self.assertFalse(self.sentinel.exists(), "version was evaluated as shell")

    def snapshot(self):
        return {f: (self.worktree / f).read_bytes() for f in self.baseline}

    def bump(self, *args, succeeds=True):
        result = run("bash", str(ROOT / "scripts/bump-release.sh"), *args, cwd=self.worktree)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def full_digests(self, version="0.4.3"):
        args = [item for svc in SERVICES for item in ("--digest", svc + "=" + DIGESTS[svc])]
        self.bump(*args, version)

    def identities(self):
        stack = load(self.worktree / "charts/permesi-stack/values.yaml")
        standalone = {svc: load(self.worktree / "charts" / svc / "values.yaml") for svc in SERVICES}
        return stack, standalone

    def assert_versions(self, chart_version, app_version):
        for svc in (*SERVICES, "permesi-stack"):
            chart = load(self.worktree / "charts" / svc / "Chart.yaml")
            self.assertEqual(chart["version"], chart_version)
            self.assertEqual(chart["appVersion"], app_version)
            if svc == "permesi-stack":
                for dep in chart["dependencies"]:
                    if dep["name"] in SERVICES:
                        self.assertEqual(dep["version"], chart_version)

    def test_full_digests_do_not_regress_chart_version(self):
        self.full_digests()
        self.assert_versions("0.4.5", "0.4.3")
        stack, standalone = self.identities()
        for svc in SERVICES:
            self.assertEqual(standalone[svc]["image"]["tag"], "0.4.3")
            self.assertEqual(standalone[svc]["image"]["digest"], DIGESTS[svc])
            self.assertEqual(stack[svc]["image"], standalone[svc]["image"])

    def test_tag_only_clears_every_stale_digest_and_preserves_agent(self):
        self.full_digests()
        before = self.identities()[1]
        self.bump("v0.4.6")
        self.assert_versions("0.4.6", "0.4.6")
        stack, standalone = self.identities()
        for svc in SERVICES:
            self.assertEqual(standalone[svc]["image"]["tag"], "0.4.6")
            self.assertEqual(standalone[svc]["image"]["digest"], "")
            self.assertEqual(stack[svc]["image"], standalone[svc]["image"])
            if svc != "web":
                self.assertEqual(standalone[svc]["vault"]["agent"]["image"],
                                 before[svc]["vault"]["agent"]["image"])

    def test_chart_only_retains_all_values_and_app_versions(self):
        self.full_digests()
        before = {svc: (self.worktree / "charts" / svc / "values.yaml").read_bytes()
                  for svc in (*SERVICES, "permesi-stack")}
        self.bump("--chart-only", "0.4.9")
        self.assert_versions("0.4.9", "0.4.3")
        for svc, data in before.items():
            self.assertEqual((self.worktree / "charts" / svc / "values.yaml").read_bytes(), data)

    def test_independent_chart_version_and_explicit_tag_only(self):
        self.bump("--chart-version", "0.5.0", "--tag-only", "0.4.3")
        self.assert_versions("0.5.0", "0.4.3")

    def test_invalid_inputs_mutate_nothing(self):
        d = DIGESTS["permesi"]
        cases = [
            ["0.4.5", "--digest", "permesi=" + d],
            ["0.4.5", "--digest", "permesi=sha256:invalid"],
            ["0.4.5", "--digest", "unknown=" + d],
            ["0.4.5", "--digest", "permesi=" + d, "--digest", "permesi=" + d],
            ["0.4.5", "--tag-only", "--digest", "permesi=" + d],
            [f"$(touch {self.sentinel})"],
            ["--chart-version", "0.4.3", "0.4.5"],
            ["--chart-version", "bad", "--chart-version", "0.4.8", "0.4.5"],
            ["--chart-version", "", "0.4.5"],
            ["--chart-only", "0.4.4"],
            ["--chart-only", "0.4.5", "--digest", "permesi=" + d],
            ["--chart-only", "0.4.5", "--tag-only"],
            ["0.4.5", "--unknown"],
        ]
        baseline = self.snapshot()
        for args in cases:
            with self.subTest(args=args):
                self.bump(*args, succeeds=False)
                self.assertEqual(self.snapshot(), baseline)

    def test_bad_managed_values_fail_before_any_rewrite(self):
        path = self.worktree / "charts/permesi-stack/values.yaml"
        path.write_text(path.read_text().replace("    digest:", "    not-a-digest:"))
        baseline = self.snapshot()
        self.bump("0.4.5", succeeds=False)
        self.assertEqual(self.snapshot(), baseline)


if __name__ == "__main__":
    unittest.main(verbosity=2)
