#!/usr/bin/env python3
"""Import the exact OCI manifests and prepare an isolated chart qualification record."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

current, previous = os.environ["APP_SHA"], os.environ["PREVIOUS_SHA"]
destination = Path(os.environ["RUNNER_TEMP"]) / "fixture"
prepare = ["python3", "scripts/ci/prepare-application-fixture.py", "--app-source", "application",
           "--destination", str(destination)]
with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as environment:
    for checkout, services, revision in [("application", ("permesi", "genesis", "web"), current),
                                         ("previous", ("permesi",), previous)]:
        for svc in services:
            archive = Path("archives") / f"{checkout}-{svc}.tar"
            with tarfile.open(archive) as source:
                index = json.load(source.extractfile("index.json"))
                manifest, = index["manifests"]
                reference = manifest["annotations"]["org.opencontainers.image.ref.name"]
                repo = "localhost/permesi-candidate/" + svc
                if reference != repo + ":" + revision:
                    raise ValueError("archive repository or build revision mismatch")
                digest = manifest["digest"]
                body = source.extractfile("blobs/sha256/" + digest.removeprefix("sha256:")).read()
                if "sha256:" + hashlib.sha256(body).hexdigest() != digest:
                    raise ValueError("manifest checksum mismatch")
            subprocess.run(["kind", "load", "image-archive", "--name", "containment", str(archive)], check=True)
            # CRI must resolve the repository@digest used by a Never-pull Pod.
            # OCI archive import can leave only a tagged alias in containerd.
            for node in subprocess.check_output(["kind", "get", "nodes", "--name", "containment"], text=True).split():
                runtime = [os.environ.get("KIND_EXPERIMENTAL_PROVIDER", "docker"), "exec", node]
                ctr = runtime + ["ctr", "-n", "k8s.io", "images"]
                pinned = repo + "@" + digest
                def target_digest(name):
                    lines = subprocess.check_output(ctr + ["ls", "name==" + name], text=True).splitlines()
                    rows = [line.split() for line in lines if line.split()[:1] == [name]]
                    if len(rows) != 1:
                        raise ValueError("containerd lacks one exact image target")
                    return rows[0][2]
                if target_digest(reference) != digest:
                    raise ValueError("imported containerd target differs from verified archive manifest")
                if pinned not in subprocess.check_output(ctr + ["ls", "-q"], text=True).splitlines():
                    subprocess.run(ctr + ["tag", reference, pinned], check=True)
                if target_digest(pinned) != digest:
                    raise ValueError("pinned repository alias resolves to an unexpected manifest")
                cri = json.loads(subprocess.check_output(runtime + ["crictl", "inspecti", pinned]))
                if pinned not in cri["status"]["repoDigests"]:
                    raise ValueError("candidate manifest unavailable through CRI")
            if checkout == "application":
                prepare.extend(["--image", svc + "=" + reference + "@" + digest])
            if svc == "permesi":
                print(("CURRENT_IMAGE" if checkout == "application" else "PREVIOUS_IMAGE") + "=" + repo + "@" + digest,
                      file=environment)
subprocess.run(prepare, check=True)
