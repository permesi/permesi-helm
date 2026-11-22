#!/usr/bin/env python3
"""Exercise the release receiver and exact authenticated package in an existing disposable KinD."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import tomllib

from release_fixture import ROOT, SERVICES


def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("app-source", "source-archive", "archives", "admission-bin"):
        parser.add_argument("--" + flag, required=True, type=Path)
    parser.add_argument("--cluster", required=True)
    args = parser.parse_args()
    revision = run("git", "-C", args.app_source, "rev-parse", "HEAD")
    version = tomllib.loads(run("git", "-C", args.app_source, "show", "HEAD:Cargo.toml"))["workspace"]["package"]["version"]
    current = json.loads((ROOT / "scripts/quickstart/lock.json").read_text())["images"]["permesi"]["tag"]
    if tuple(map(int, version.split("."))) <= tuple(map(int, current.split("."))):
        print("No upcoming application version. Charts CI qualifies the published release.")
        return
    with tempfile.TemporaryDirectory(prefix="simulate-release-") as temp:
        tree = Path(temp)
        for folder in ("charts", "scripts"):
            shutil.copytree(ROOT / folder, tree / folder, ignore=shutil.ignore_patterns("*.tgz", "__pycache__", "target"))
        shutil.copyfile(ROOT / "README.md", tree / "README.md")
        images = {}
        runtime = os.environ.get("KIND_EXPERIMENTAL_PROVIDER", "docker")
        for svc in SERVICES:
            archive = args.archives / ("application-" + svc + ".tar")
            with tarfile.open(archive) as source:
                manifest, = json.load(source.extractfile("index.json"))["manifests"]
            reference = manifest["annotations"]["org.opencontainers.image.ref.name"]
            if reference != "localhost/permesi-candidate/" + svc + ":" + revision:
                raise ValueError("unexpected application archive")
            repo = "ghcr.io/permesi/" + svc
            images[svc] = {"repository": repo, "tag": version, "digest": manifest["digest"]}
            # Local aliases represent the release repositories inside this disposable node only.
            for node in run("kind", "get", "nodes", "--name", args.cluster).splitlines():
                ctr = [runtime, "exec", node, "ctr", "-n", "k8s.io", "images"]
                pinned = repo + "@" + manifest["digest"]
                if pinned not in run(*ctr, "ls", "-q").splitlines():
                    run(*ctr, "tag", reference, pinned)
                line, = run(*ctr, "ls", "name==" + pinned).splitlines()[1:]
                if line.split()[2] != manifest["digest"]:
                    raise ValueError("simulated registry identity differs from the imported archive")
        event = tree / "event.json"
        event.write_text(json.dumps({"client_payload": {"version": version, "source_repo": "permesi/permesi",
                                    "source_tag": version, "source_sha": revision, "images": images}}))
        outputs = tree / "outputs"
        run("bash", ROOT / "scripts/ci/release-event.sh", env={**os.environ, "GITHUB_EVENT_NAME": "repository_dispatch",
            "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(outputs)})
        meta = dict(line.split("=", 1) for line in outputs.read_text().splitlines())
        subprocess.run(["python3", ROOT / "scripts/ci/apply-release.py", "--root", tree, "--app-source", args.app_source,
                        "--version", meta["version"], "--revision", meta["source_sha"], "--archive", args.source_archive,
                        *[arg for svc in SERVICES for arg in ("--digest", svc + "=" + meta[svc + "_digest"])]], check=True)
        subprocess.run(["python3", ROOT / "scripts/quickstart/tests/real-packaged-stack.py", "--fixture", tree,
                        "--namespace", "qv-release-simulation", "--context", "kind-" + args.cluster,
                        "--app-source", args.app_source, "--admission-bin", args.admission_bin], check=True)


if __name__ == "__main__":
    main()
