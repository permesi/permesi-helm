"""Resolve an application CI artifact and import only its three verified OCI archives."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

API = "repos/permesi/permesi"
SERVICES = ("permesi", "genesis", "web")


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", API + "/" + path]))


def verify_metadata(artifact, run, sha, expected_digest):
    """Require the immutable artifact from the expected sandbox build run and repository."""
    digest = artifact["digest"]
    if (not re.fullmatch(r"[0-9a-f]{40}", sha) or
            not re.fullmatch(r"sha256:[0-9a-f]{64}", digest) or
            digest.removeprefix("sha256:") != expected_digest.removeprefix("sha256:") or
            artifact["expired"] or not isinstance(artifact["workflow_run"], dict) or
            not re.fullmatch("sandbox-oci-" + sha + r"(?:-[1-9][0-9]*)?", artifact["name"]) or
            run["head_sha"] != sha or run["head_branch"] != "sandbox" or
            run["repository_id"] != run["head_repository_id"] or
            any(artifact["workflow_run"].get(key) != run[key]
                for key in ("id", "head_sha", "head_branch", "repository_id", "head_repository_id"))):
        raise ValueError("OCI artifact identity disagrees with the sandbox build")


def successful_image_attempt(jobs):
    """A failed downstream qualification can be retried against the successful upstream build."""
    latest = {}
    for job in sorted(jobs, key=lambda item: item["id"]):
        latest[job["name"]] = job
    names = ("CI OK", "coverage / Coverage", "Build local OCI candidates")
    if all(latest.get(name, {}).get("conclusion") == "success" for name in names):
        return latest[names[-1]]["run_attempt"]
    return None


def resolve():
    supplied = os.environ.get("ARTIFACT_ID")
    if supplied:
        if (os.environ["GITHUB_REPOSITORY"] != "permesi/permesi" or
                os.environ["GITHUB_REF"] != "refs/heads/sandbox" or not supplied.isdecimal()):
            raise ValueError("expected the application sandbox build as caller")
        sha = os.environ["GITHUB_SHA"]
        run_id = int(os.environ["GITHUB_RUN_ID"])
        expected = os.environ["ARTIFACT_DIGEST"]
        artifact = api("actions/artifacts/" + supplied)
    else:
        if os.environ["GITHUB_REPOSITORY"] != "permesi/permesi-helm" or os.environ["GITHUB_REF"] != "refs/heads/sandbox":
            raise ValueError("chart-only qualification requires the Helm sandbox")
        sha = api("git/ref/heads/sandbox")["object"]["sha"]
        runs = api(f"actions/workflows/build.yml/runs?branch=sandbox&head_sha={sha}&per_page=100")
        for candidate in sorted(runs["workflow_runs"], key=lambda row: row["id"], reverse=True):
            if candidate["event"] not in ("push", "workflow_dispatch"):
                continue
            run_id = candidate["id"]
            pages = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp",
                f"{API}/actions/runs/{run_id}/jobs?filter=all&per_page=100"]))
            attempt = successful_image_attempt([job for page in pages for job in page["jobs"]])
            if attempt:
                break
        else:
            raise ValueError("no successful application CI gates at the current sandbox revision")
        records = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp",
            f"{API}/actions/runs/{run_id}/artifacts?per_page=100"]))
        names = {"sandbox-oci-" + sha + "-" + str(attempt)}
        if attempt == 1:
            names.add("sandbox-oci-" + sha)
        artifact, = [item for page in records for item in page["artifacts"] if item["name"] in names]
        expected = artifact["digest"]
    run = api(f"actions/runs/{run_id}")
    if (run["path"] != ".github/workflows/build.yml" or run["event"] not in ("push", "workflow_dispatch")
            or run["head_repository"]["full_name"] != "permesi/permesi"):
        raise ValueError("unexpected source workflow")
    metadata = {**run, "repository_id": run["repository"]["id"], "head_repository_id": run["head_repository"]["id"]}
    verify_metadata(artifact, metadata, sha, expected)
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        for key, value in {"app_sha": sha, "helm_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                           "artifact_id": artifact["id"], "artifact_digest": artifact["digest"]}.items():
            print(f"{key}={value}", file=out)


def unpack(path, digest, destination):
    """Validate the downloaded ZIP before writing any candidate archive."""
    with path.open("rb") as stream:
        if "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest() != digest:
            raise ValueError("OCI artifact ZIP checksum mismatch")
    with zipfile.ZipFile(path) as archive:
        if sorted(archive.namelist()) != sorted(service + ".tar" for service in SERVICES):
            raise ValueError("expected exactly three application OCI archives")
        for service in SERVICES:
            with archive.open(service + ".tar") as source, (destination / f"application-{service}.tar").open("wb") as output:
                shutil.copyfileobj(source, output)


if __name__ == "__main__":
    if sys.argv[1:] == ["resolve"]:
        resolve()
    elif sys.argv[1:] == ["download"]:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "artifact.zip"
            with bundle.open("wb") as output:
                subprocess.run(["gh", "api", f'{API}/actions/artifacts/{int(os.environ["ARTIFACT_ID"])}/zip'],
                               stdout=output, check=True)
            unpack(bundle, os.environ["ARTIFACT_DIGEST"], Path("archives"))
    else:
        raise SystemExit("expected resolve or download")
