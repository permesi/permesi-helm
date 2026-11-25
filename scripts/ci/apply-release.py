#!/usr/bin/env python3
"""Apply one authenticated application release to a disposable release checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile
import subprocess
import sys

import yaml

from openbao_release import promote
from release_fixture import DIGEST, ROOT, SERVICES, SHA, VERSION, validate


def version_tuple(value):
    if not re.fullmatch(VERSION, value):
        raise ValueError("invalid release version")
    return tuple(map(int, value.split(".")))


def stage(root, app, archive, version, revision, images, chart_version=None):
    """Reject stale or conflicting deliveries and revalidate even exact replays."""
    lock = validate(root)
    old = lock["images"]["permesi"]["tag"]
    if version_tuple(version) < version_tuple(old):
        raise ValueError("stale application release")
    if not re.fullmatch(SHA, revision) or set(images) != set(SERVICES) or not all(
            re.fullmatch(DIGEST, d) for d in images.values()):
        raise ValueError("expected one source commit and three immutable release images")
    repeat = version == old
    chart = str(yaml.safe_load((root / "charts/permesi-stack/Chart.yaml").read_text())["version"])
    if repeat and (revision != lock["appRevision"] or
                   hashlib.sha256(archive.read_bytes()).hexdigest() != lock["appArchiveSha256"] or
                   any(images[s] != lock["images"][s]["digest"] for s in SERVICES) or
                   (chart_version and chart != chart_version)):
        raise ValueError("conflicting repeated release")
    args = [item for service in SERVICES for item in ("--digest", service + "=" + images[service])]
    if not repeat:
        subprocess.run(["bash", "scripts/bump-release.sh", *args,
                        *(["--chart-version", chart_version] if chart_version else []), version], cwd=root, check=True)
    # Idempotent: the first 0.6 release replaces the 0.5 dependency entries; later
    # locks are already held to the pins by the fixture validation above.
    if version_tuple(version) >= (0, 6, 0):
        promote(root)
    subprocess.run([sys.executable, ROOT / "scripts/ci/refresh-release-fixture.py", "--root", root,
                    "--app-source", app, "--archive", archive, "--version", version,
                    "--revision", revision, *args], check=True)
    subprocess.run(["helm", "dependency", "update", "--skip-refresh", root / "charts/permesi-stack"], check=True)


def apply(root, app, archive, version, revision, images, chart_version=None):
    """Discard the entire staged release if validation, packaging or SQL verification fails."""
    with tempfile.TemporaryDirectory() as directory:
        tree = Path(directory)
        for name in ("charts", "scripts"):
            shutil.copytree(root / name, tree / name, ignore=shutil.ignore_patterns("*.tgz", "__pycache__", "Chart.lock", "target"))
        shutil.copyfile(root / "README.md", tree / "README.md")
        stage(tree, app, archive, version, revision, images, chart_version)
        for dest in tree.rglob("*"):
            relative = dest.relative_to(tree)
            if dest.is_file() and (root / relative).is_file() and dest.name != "Chart.lock" and dest.suffix != ".tgz":
                if dest.read_bytes() != (root / relative).read_bytes():
                    shutil.copyfile(dest, root / relative)
        subprocess.run(["helm", "dependency", "update", "--skip-refresh", root / "charts/permesi-stack"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--chart-version")
    parser.add_argument("--digest", action="append", required=True)
    args = parser.parse_args()
    if len(args.digest) != 3:
        parser.error("three distinct digests required")
    apply(args.root.resolve(), args.app_source.resolve(), args.archive.resolve(), args.version, args.revision,
          dict(value.split("=", 1) for value in args.digest), args.chart_version)
