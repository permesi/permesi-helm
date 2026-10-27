#!/usr/bin/env python3
"""Validate release qualification pins and expose only their validated SQL revision."""
import argparse
from pathlib import Path
import sys

from release_fixture import ROOT, validate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        lock = validate(args.root)
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"release fixture: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write("app_revision=" + lock["appRevision"] + "\n")
    print("Release fixture matches application images and SQL revision " + lock["appRevision"])


if __name__ == "__main__":
    main()
