#!/usr/bin/env python3
"""Validate the four product chart versions and their umbrella references.

Application versions and the development helper chart have independent lifecycles.
This read-only check is shared by CI and both publication workflows.
"""
import argparse
from pathlib import Path
import re
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ("permesi", "genesis", "web")


class ChartLoader(yaml.SafeLoader):
    """Reject duplicate fields rather than disagreeing with other release readers."""


def unique_mapping(loader, node):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if key in mapping:
            raise ValueError("duplicate chart metadata field")
        mapping[key] = loader.construct_object(value_node)
    return mapping


ChartLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def validate(root, expected=None):
    """Return the synchronized version, failing before any release or registry write."""
    charts = {}
    for name in (*COMPONENTS, "permesi-stack"):
        chart = yaml.load((root / "charts" / name / "Chart.yaml").read_text(), Loader=ChartLoader)
        if not isinstance(chart, dict) or chart.get("name") != name:
            raise ValueError(f"invalid metadata for chart {name}")
        version = chart.get("version")
        if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
            raise ValueError(f"invalid version for chart {name}")
        charts[name] = chart
    version = charts["permesi-stack"]["version"]
    if expected is not None and version != expected:
        raise ValueError(f"umbrella version {version}, expected {expected}")
    for name, chart in charts.items():
        if chart["version"] != version:
            raise ValueError(f"chart {name} has version {chart['version']}, expected {version}")
    dependencies = charts["permesi-stack"].get("dependencies")
    if not isinstance(dependencies, list) or not all(isinstance(d, dict) for d in dependencies):
        raise ValueError("invalid umbrella dependencies")
    for name in COMPONENTS:
        matches = [d for d in dependencies if d.get("name") == name]
        if len(matches) != 1 or matches[0].get("version") != version:
            raise ValueError(f"umbrella dependency {name} must occur once at version {version}")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--expected", help="Version requested by a release or publish event")
    args = parser.parse_args()
    try:
        version = validate(args.root, args.expected)
    except (OSError, TypeError, ValueError, yaml.YAMLError) as error:
        print(f"chart versions: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    print(f"Chart versions and umbrella dependencies aligned at {version}")


if __name__ == "__main__":
    main()
