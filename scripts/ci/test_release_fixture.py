#!/usr/bin/env python3
"""Prove release pins advance together and invalid sources cannot rewrite fixtures."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

import yaml

from release_fixture import ROOT, SERVICES, refresh, validate


class ReleaseFixtureTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name) / "helm"
        for name in ("scripts/quickstart/lock.json", "scripts/quickstart/chart/values.yaml",
                     "charts/permesi-stack/values.yaml", "charts/permesi-stack/Chart.yaml",
                     *[f"charts/{s}/{n}" for s in SERVICES for n in ("Chart.yaml", "values.yaml")]):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        self.version = "0.4.9"
        self.digests = {name: "sha256:" + char * 64 for name, char in zip(SERVICES, "abc")}
        for service in SERVICES:
            chart_path = self.root / "charts" / service / "Chart.yaml"
            chart = yaml.safe_load(chart_path.read_text())
            chart["appVersion"] = self.version
            chart_path.write_text(yaml.safe_dump(chart))
            for path in (self.root / "charts" / service / "values.yaml", self.root / "charts/permesi-stack/values.yaml"):
                values = yaml.safe_load(path.read_text())
                image = values["image"] if path.parent.name == service else values[service]["image"]
                image.update(tag=self.version, digest=self.digests[service])
                path.write_text(yaml.safe_dump(values))
        stack_chart_path = self.root / "charts/permesi-stack/Chart.yaml"
        stack_chart = yaml.safe_load(stack_chart_path.read_text())
        stack_chart["appVersion"] = self.version
        stack_chart_path.write_text(yaml.safe_dump(stack_chart))
        self.app = Path(scratch.name) / "app"
        (self.app / "db/sql").mkdir(parents=True)
        (self.app / "db/sql/00_init.sql").write_text("SELECT 1;\n")
        (self.app / "Cargo.toml").write_text(f'[workspace.package]\nversion = "{self.version}"\n')
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.app), *args], text=True).strip()
        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.test")
        git("add", "db/sql", "Cargo.toml")
        git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Create fixture schema")
        self.revision = git("rev-parse", "HEAD")
        self.archive = Path(scratch.name) / "source.tar.gz"
        self.make_archive()

    def make_archive(self, body=b"SELECT 1;\n", revision=None):
        with tarfile.open(self.archive, "w:gz") as archive:
            info = tarfile.TarInfo(f"permesi-{revision or self.revision}/db/sql/00_init.sql")
            info.size = len(body)
            archive.addfile(info, io.BytesIO(body))

    def snapshot(self):
        return {str(path): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}

    def update(self, **overrides):
        args = dict(root=self.root, app_source=self.app, archive=self.archive, version=self.version,
                    revision=self.revision, digests=self.digests)
        args.update(overrides)
        refresh(**args)

    def test_refresh_advances_exact_release_images_sql_revision_and_archive_checksum(self):
        old = json.loads((self.root / "scripts/quickstart/lock.json").read_text())
        self.update()
        lock = validate(self.root)
        self.assertEqual(lock["appRevision"], self.revision)
        self.assertEqual(lock["appArchiveSha256"], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        for service in SERVICES:
            self.assertEqual(lock["images"][service]["digest"], self.digests[service])
            self.assertEqual(lock["images"][service]["tag"], self.version)
        for dependency in ("postgresql", "vault"):
            self.assertEqual(lock["images"][dependency], old["images"][dependency])

    def test_revision_digest_and_archive_mismatch_leave_all_files_unchanged(self):
        for overrides in ({"revision": "d" * 40}, {"digests": {"permesi": self.digests["permesi"]}},
                          {"version": "$(touch sentinel)"}, {"version": "0.4.8"}):
            with self.subTest(overrides=overrides):
                before = self.snapshot()
                with self.assertRaises(ValueError):
                    self.update(**overrides)
                self.assertEqual(self.snapshot(), before)
        self.make_archive(b"SELECT 2;\n")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.update()
        self.assertEqual(self.snapshot(), before)

    def test_stale_fixture_and_dirty_sql_checkout_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "disagree"):
            validate(self.root)
        before = self.snapshot()
        (self.app / "db/sql/00_init.sql").write_text("SELECT 3;\n")
        with self.assertRaisesRegex(ValueError, "clean"):
            self.update()
        self.assertEqual(self.snapshot(), before)

    def test_unsafe_and_duplicate_sql_archive_members_are_rejected_before_mutation(self):
        for member_name, duplicate in ((f"permesi-{self.revision}/db/sql/../00_init.sql", False),
                                       (f"permesi-{'f' * 40}/db/sql/00_init.sql", False),
                                       (f"permesi-{self.revision}/db/sql/00_init.sql", True)):
            with self.subTest(member_name=member_name, duplicate=duplicate):
                with tarfile.open(self.archive, "w:gz") as archive:
                    for _ in range(2 if duplicate else 1):
                        info = tarfile.TarInfo(member_name)
                        info.size = 10
                        archive.addfile(info, io.BytesIO(b"SELECT 1;\n"))
                before = self.snapshot()
                with self.assertRaises(ValueError):
                    self.update()
                self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
