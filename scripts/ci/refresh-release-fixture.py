#!/usr/bin/env python3
"""Refresh qualification pins from a validated release, checkout and source archive."""
import argparse
from pathlib import Path
import sys

from release_fixture import ROOT, refresh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--digest", action="append", required=True)
    args = parser.parse_args()
    pairs = [value.partition("=") for value in args.digest]
    if len(pairs) != 3 or len({pair[0] for pair in pairs}) != 3 or not all(pair[1] for pair in pairs):
        parser.error("supply exactly three service=sha256:... digests")
    try:
        refresh(args.root, args.app_source, args.archive, args.version, args.revision,
                {name: value for name, _, value in pairs})
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"release fixture: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    print("Refreshed matching release image and SQL fixture pins")


if __name__ == "__main__":
    main()
