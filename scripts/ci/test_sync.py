"""Exercise the actual release transaction, sandbox identity checks and status writer."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import runpy
import subprocess
import tempfile
import unittest
import zipfile

import yaml

from release_fixture import ROOT, SERVICES, validate
from sandbox_artifact import successful_image_attempt, unpack, verify_metadata


class ReleaseTransaction(unittest.TestCase):
    def test_new_repeated_partial_stale_and_failed_deliveries(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            for name in ("charts", "scripts"):
                shutil.copytree(ROOT / name, tree / name, ignore=shutil.ignore_patterns("__pycache__", "*.tgz", "target"))
            shutil.copyfile(ROOT / "README.md", tree / "README.md")
            # Start from a stale dependency pin so the release must promote the lock.
            lock_path = tree / "scripts/quickstart/lock.json"
            stale = json.loads(lock_path.read_text())
            stale["images"]["openbao"] = {**stale["images"]["openbao"], "tag": "2.7.2", "digest": "sha256:" + "e" * 64}
            lock_path.write_text(json.dumps(stale, indent=2) + "\n")
            pins = json.loads((tree / "scripts/quickstart/openbao-images.json").read_text())
            base = validate(ROOT)["images"]["permesi"]["tag"]
            major, minor, patch = map(int, base.split("."))
            version = "0.6.0" if (major, minor, patch) < (0, 6, 0) else f"{major}.{minor}.{patch+1}"
            app = tree / "source"
            (app / "db/sql").mkdir(parents=True)
            (app / "Cargo.toml").write_text(f'[workspace.package]\nversion="{version}"\n')
            (app / "db/sql/00_init.sql").write_text("select 1;\n")
            def git(*args):
                return subprocess.check_output(["git", "-C", app, *args], text=True).strip()
            git("init", "-q")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.test", "-c", "commit.gpgsign=false",
                "commit", "-qm", "Create source fixture")
            revision = git("rev-parse", "HEAD")
            archive = tree / "release.tar.gz"
            git("archive", "--format=tar.gz", "--prefix=permesi-" + revision + "/", "-o", str(archive), revision)
            images = {svc: "sha256:" + n * 64 for svc, n in zip(SERVICES, "abc")}
            def apply(rev=revision, tag=version, image_map=None, chart=None):
                command = ["python3", ROOT / "scripts/ci/apply-release.py", "--root", tree, "--app-source", app,
                           "--archive", archive, "--revision", rev, "--version", tag]
                for name, digest in (images if image_map is None else image_map).items():
                    command += ["--digest", name + "=" + digest]
                if chart:
                    command += ["--chart-version", chart]
                return subprocess.run(command, capture_output=True, text=True)
            def snapshot():
                return {str(p.relative_to(tree)): p.read_bytes() for folder in ("scripts", "charts")
                        for p in (tree / folder).rglob("*") if p.is_file() and p.suffix not in (".pyc", ".tgz")
                        and p.name != "Chart.lock"}
            initial = snapshot()
            for rejected in (apply(rev="d"*40), apply(image_map={"permesi": images["permesi"]}), apply(tag="0.0.1")):
                self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(snapshot(), initial)
            chart_version = f"{major+1}.0.0"
            result = apply(chart=chart_version)
            self.assertEqual(result.returncode, 0, result.stderr)
            lock = validate(tree)
            self.assertEqual(lock["appRevision"], revision)
            self.assertEqual(lock["appArchiveSha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(lock["images"]["openbao"], pins["openbao"])
            self.assertEqual(lock["images"]["postgresql"], pins["postgresql"])
            self.assertNotIn("vault", lock["images"])
            self.assertEqual(str(yaml.safe_load((tree / "charts/permesi-stack/Chart.yaml").read_text())["version"]), chart_version)
            committed = snapshot()
            self.assertEqual(apply().returncode, 0)
            self.assertNotEqual(apply(image_map={**images, "web": "sha256:"+"d"*64}).returncode, 0)
            self.assertNotEqual(apply(tag=base).returncode, 0)
            self.assertEqual(snapshot(), committed)


class SourceIdentity(unittest.TestCase):
    def test_requires_matching_complete_source_metadata(self):
        digest = "sha256:" + "c"*64
        sha = "a"*40
        run = dict(id=31, repository_id=12, head_repository_id=12, head_sha=sha, head_branch="sandbox")
        artifact = dict(digest=digest, name="sandbox-oci-"+sha+"-2", expired=False, workflow_run=run)
        verify_metadata(artifact, run, sha, digest)
        for change in ({"expired": True}, {"workflow_run": {}}, {"workflow_run": {**run, "id": 30}},
                       {"name": "sandbox-oci-"+ "b"*40}, {"digest": "sha256:"+"f"*64}):
            with self.assertRaises(ValueError):
                verify_metadata({**artifact, **change}, run, sha, digest)

    def test_chart_fix_can_retry_the_exact_successful_build_after_failed_qualification(self):
        names = ("CI OK", "coverage / Coverage", "Build local OCI candidates")
        jobs = [dict(name=name, id=n, conclusion="success", run_attempt=1) for n, name in enumerate(names)]
        jobs.append(dict(name="containment / qualify (shared)", id=10, conclusion="failure", run_attempt=1))
        self.assertEqual(successful_image_attempt(jobs), 1)
        jobs.append(dict(name=names[0], id=11, conclusion="failure", run_attempt=2))
        self.assertIsNone(successful_image_attempt(jobs))

    def test_download_rejects_checksum_and_incomplete_archives(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)
            path = dest / "bundle.zip"
            with zipfile.ZipFile(path, "w") as archive:
                for name in SERVICES:
                    archive.writestr(name+".tar", name)
            with self.assertRaisesRegex(ValueError, "checksum"):
                unpack(path, "sha256:"+"a"*64, dest)
            unpack(path, "sha256:"+hashlib.sha256(path.read_bytes()).hexdigest(), dest)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("permesi.tar", "partial")
            with self.assertRaisesRegex(ValueError, "three"):
                unpack(path, "sha256:"+hashlib.sha256(path.read_bytes()).hexdigest(), dest)

    def test_failed_rerun_retains_prior_attested_pair(self):
        recorded = runpy.run_path(str(ROOT / "scripts/ci/last-qualified.py"))["recorded"]
        url = "https://github.com/permesi/permesi/actions/runs/1234"
        run = dict(id=1234, run_attempt=2, html_url=url, head_sha="a"*40, conclusion="failure")
        status = dict(context="containment/1234/1", state="success", creator={"login": "github-actions[bot]"},
                      target_url=url+"/attempts/1", description="Helm " + "b"*40 + ", OCI artifact 101")
        self.assertEqual(recorded("permesi", run, [status])["artifact_id"], 101)
        self.assertIsNone(recorded("permesi", run, [{**status, "target_url": url+"/attempts/2"}]))

    def test_failed_stale_and_out_of_order_attempts_cannot_replace_another_status(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/containment-ci.yml").read_text())["jobs"]
        self.assertEqual(set(jobs["record"]["needs"]), {"images", "qualify"})
        self.assertNotIn("if", jobs["record"])
        self.assertEqual(set(jobs["qualify"]["strategy"]["matrix"]["profile"]), {"shared", "isolated"})
        command = jobs["record"]["steps"][-1]["run"]
        with tempfile.TemporaryDirectory() as directory:
            gh = Path(directory) / "gh"
            gh.write_text('#!/bin/sh\ncase "$2" in */permesi/git/*) echo "$APP_HEAD";; */permesi-helm/git/*) echo "$CHART_HEAD";; */statuses/*) echo "$*" >> "$LEDGER";; *) exit 2;; esac\n')
            gh.chmod(0o700)
            ledger = Path(directory) / "ledger"
            env = dict(os.environ, PATH=directory+":"+os.environ["PATH"], APP_SHA="a"*40, HELM_SHA="b"*40,
                       APP_HEAD="a"*40, CHART_HEAD="b"*40, GITHUB_SHA="a"*40, GITHUB_REPOSITORY="permesi/permesi",
                       ARTIFACT_ID="9", GITHUB_RUN_ID="12", GITHUB_RUN_ATTEMPT="2", GITHUB_SERVER_URL="https://github.com",
                       LEDGER=str(ledger))
            for change, success in (({}, True), ({"APP_HEAD":"f"*40}, False), ({"CHART_HEAD":"f"*40}, False),
                                    ({"GITHUB_RUN_ATTEMPT":"1"}, True)):
                result = subprocess.run(["bash", "-c", command], env={**env, **change})
                self.assertEqual(result.returncode == 0, success)
            lines = ledger.read_text().splitlines()
            self.assertEqual(len(lines), 2)
            self.assertIn("context=containment/12/2", lines[0])
            self.assertIn("context=containment/12/1", lines[1])
