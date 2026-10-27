"""Keep release qualification images, SQL revision and archive checksum together.

Release event values remain data. Only an exact clean application checkout and an
archive containing identical SQL can refresh the fixture; validation precedes writes.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tomllib

import yaml

ROOT = Path(__file__).resolve().parents[2]
SERVICES = ("permesi", "genesis", "web")
SHA = r"[0-9a-f]{40}"
DIGEST = r"sha256:[0-9a-f]{64}"
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def validate(root, lock=None, schema=None):
    """Check committed pins without executing a value or contacting a service."""
    if lock is None:
        lock = json.loads((root / "scripts/quickstart/lock.json").read_text())
    if lock.get("platform") != "linux/amd64":
        raise ValueError("qualification currently requires linux/amd64 images")
    if not re.fullmatch(SHA, lock["appRevision"]) or not re.fullmatch(r"[0-9a-f]{64}", lock["appArchiveSha256"]):
        raise ValueError("invalid application revision or archive checksum")
    for service in SERVICES:
        image = lock["images"][service]
        if (image["repository"] != f"ghcr.io/permesi/{service}" or
                not re.fullmatch(VERSION, image["tag"]) or not re.fullmatch(DIGEST, image["digest"])):
            raise ValueError(f"invalid immutable image fixture for {service}")
        values = yaml.safe_load((root / "charts" / service / "values.yaml").read_text())["image"]
        stack_values = yaml.safe_load((root / "charts/permesi-stack/values.yaml").read_text())[service]["image"]
        for selected in (values, stack_values):
            if any(selected[key] != image[key] for key in ("repository", "tag")) or selected.get("digest") not in ("", image["digest"]):
                raise ValueError(f"release image and test fixture disagree for {service}")
        chart = yaml.safe_load((root / "charts" / service / "Chart.yaml").read_text())
        if str(chart["appVersion"]) != image["tag"]:
            raise ValueError(f"appVersion and image fixture disagree for {service}")
    tags = {lock["images"][service]["tag"] for service in SERVICES}
    if len(tags) != 1:
        raise ValueError("application fixture images must belong to one release")
    stack_chart = yaml.safe_load((root / "charts/permesi-stack/Chart.yaml").read_text())
    if str(stack_chart["appVersion"]) not in tags:
        raise ValueError("umbrella appVersion and image fixture disagree")
    if schema is None:
        schema = yaml.safe_load((root / "scripts/quickstart/chart/values.yaml").read_text())["bootstrap"]["schema"]
    if (schema["revision"] != lock["appRevision"] or schema["sha256"] != lock["appArchiveSha256"] or
            schema["sourceUrl"] != f"https://github.com/permesi/permesi/archive/{lock['appRevision']}.tar.gz"):
        raise ValueError("helper SQL source and release fixture disagree")
    return lock


def refresh(root, app_source, archive, version, revision, digests):
    """Stage pins only after proving all three image identities and exact SQL bytes."""
    if not re.fullmatch(VERSION, version) or not re.fullmatch(SHA, revision):
        raise ValueError("invalid application version or revision")
    if set(digests) != set(SERVICES) or not all(re.fullmatch(DIGEST, value) for value in digests.values()):
        raise ValueError("all three immutable image digests are required")
    head = subprocess.check_output(["git", "-C", str(app_source), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(app_source), "status", "--porcelain", "--", "db/sql"], text=True)
    if head != revision or dirty:
        raise ValueError("application SQL checkout must be clean at the release revision")
    manifest = subprocess.check_output(["git", "-C", str(app_source), "show", "HEAD:Cargo.toml"], text=True)
    if tomllib.loads(manifest)["workspace"]["package"]["version"] != version:
        raise ValueError("release version does not match the application source commit")
    sql_files = list((app_source / "db/sql").rglob("*.sql"))
    if any(path.is_symlink() for path in sql_files):
        raise ValueError("SQL source must contain regular files")
    sql = {path.relative_to(app_source / "db/sql").as_posix(): path.read_bytes() for path in sql_files}
    if "00_init.sql" not in sql:
        raise ValueError("canonical application SQL is missing")
    archived = {}
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            parts = PurePosixPath(member.name).parts
            if len(parts) < 4 or parts[1:3] != ("db", "sql") or not member.name.endswith(".sql"):
                continue
            relative = PurePosixPath(*parts[3:])
            if (parts[0] != f"permesi-{revision}" or ".." in relative.parts or
                    not member.isfile() or member.size > 8 * 1024 * 1024 or str(relative) in archived):
                raise ValueError("unsafe or duplicate SQL archive member")
            source = bundle.extractfile(member)
            if source is None:
                raise ValueError("unreadable SQL archive member")
            archived[str(relative)] = source.read()
    if archived != sql:
        raise ValueError("release archive SQL does not match the exact application checkout")
    lock_path = root / "scripts/quickstart/lock.json"
    helper_path = root / "scripts/quickstart/chart/values.yaml"
    lock = json.loads(lock_path.read_text())
    lock["appRevision"] = revision
    lock["appArchiveSha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    for service in SERVICES:
        lock["images"][service] = {"repository": f"ghcr.io/permesi/{service}", "tag": version,
                                    "digest": digests[service]}
    helper = helper_path.read_text()
    replacements = {"sourceUrl": f"https://github.com/permesi/permesi/archive/{revision}.tar.gz",
                    "sha256": lock["appArchiveSha256"], "revision": revision}
    for key, value in replacements.items():
        helper, count = re.subn(r"(?m)^(    " + key + r":).*$", lambda match: match[1] + " " + json.dumps(value), helper)
        if count != 1:
            raise ValueError(f"expected one helper schema {key} field")
    validate(root, lock, yaml.safe_load(helper)["bootstrap"]["schema"])
    # All semantic and source checks finish before either committed file changes.
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    helper_path.write_text(helper)
