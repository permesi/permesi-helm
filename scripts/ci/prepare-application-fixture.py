#!/usr/bin/env python3
"""Create isolated charts/locks for exact application images loaded into a test cluster.

Only the destination copy changes. Published defaults stay pinned in the source
checkout. Inputs name all three real image manifests; render success alone never
establishes image provenance or application compatibility.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[2]
SERVICES = ("permesi", "genesis", "web")


def image(value):
    """Require an explicit repository, tag and manifest digest for a named application."""
    service, separator, reference = value.partition("=")
    tagged, at, digest = reference.rpartition("@")
    repository, colon, tag = tagged.rpartition(":")
    if (not separator or service not in SERVICES or not at or not colon or
            not re.fullmatch(r"sha256:[0-9a-f]{64}", digest) or
            not re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]*", tag) or tag == "latest" or
            not re.fullmatch(r"[a-z0-9][a-z0-9./:_-]*", repository)):
        raise argparse.ArgumentTypeError("image must be service=repository:tag@sha256:<64 hex>")
    return service, {"repository": repository, "tag": tag, "digest": digest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--image", type=image, action="append", required=True)
    args = parser.parse_args()
    images = dict(args.image)
    if len(args.image) != 3 or set(images) != set(SERVICES):
        parser.error("supply exactly one image for each of permesi, genesis and web")
    if args.destination.exists():
        parser.error("destination must not exist")
    if args.destination.resolve().is_relative_to(ROOT.resolve()):
        parser.error("destination must be outside the source Helm checkout")
    revision = subprocess.check_output(["git", "-C", str(args.app_source), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(args.app_source), "status", "--porcelain"], text=True)
    if dirty or not (args.app_source / "db/sql/00_init.sql").is_file():
        parser.error("application source must be a clean checkout with canonical SQL")
    args.destination.mkdir(parents=True)
    for directory in ("charts", "scripts", "docs"):
        shutil.copytree(ROOT / directory, args.destination / directory,
                        ignore=shutil.ignore_patterns("__pycache__", "target"))
    lock_path = args.destination / "scripts/quickstart/lock.json"
    lock = json.loads(lock_path.read_text())
    lock["appRevision"] = revision
    lock["images"].update(images)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    for service, identity in images.items():
        values_path = args.destination / "charts" / service / "values.yaml"
        values = yaml.safe_load(values_path.read_text())
        values["image"].update(identity)
        values["image"]["pullPolicy"] = "Never"
        values_path.write_text(yaml.safe_dump(values, sort_keys=False))
    stack_path = args.destination / "charts/permesi-stack/values.yaml"
    stack = yaml.safe_load(stack_path.read_text())
    for service, identity in images.items():
        stack[service]["image"] = {**identity, "pullPolicy": "Never"}
    stack_path.write_text(yaml.safe_dump(stack, sort_keys=False))
    subprocess.run(["helm", "dependency", "update", str(stack_path.parent)], check=True)
    print(f"Prepared application fixture at {args.destination} for {revision}")


if __name__ == "__main__":
    main()
