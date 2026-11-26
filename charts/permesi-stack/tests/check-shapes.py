#!/usr/bin/env python3
"""Run from repository root with Helm and PyYAML; no cluster required."""
import subprocess
from pathlib import Path

import yaml

CHART = Path("charts/permesi-stack")
PROFILE = CHART / "examples/quickstart.yaml"


def render(chart, *args, release="permesi", namespace="permesi-quickstart"):
    return subprocess.run(
        ["helm", "template", release, str(chart), "-n", namespace, *args],
        capture_output=True, text=True, check=False,
    )


def resources(result):
    if result.returncode:
        raise AssertionError(result.stderr)
    return {
        (d["kind"], d["metadata"]["name"]): d
        for d in yaml.safe_load_all(result.stdout) if d
    }


# Disabled means the exact original component interfaces, not merely no Jobs.
# Genesis has no default admission signing version: the core operator publishes it.
defaults = resources(render(CHART, "--set", "web.runtimeConfig.allowBuildDefaults=true",
                            "--set", "genesis.admissionSigningVersion=1"))
components = {}
for name in ("permesi", "genesis", "web"):
    args = {"web": ["--set", "runtimeConfig.allowBuildDefaults=true"],
            "genesis": ["--set", "admissionSigningVersion=1"]}.get(name, [])
    components.update(resources(render(Path("charts") / name, *args)))
assert defaults == components, "disabled umbrella must equal the three component renders"
assert not any(k in ("Job", "StatefulSet", "ClusterRole", "ClusterRoleBinding") for k, _ in defaults)
print("PASS: disabled helper adds no resources and preserves every component manifest")

full = resources(render(CHART, "-f", str(PROFILE)))
assert not any(k == "Secret" for k, _ in full), "no rendered app credential Secrets"
assert sum(k == "Job" for k, _ in full) == 2
for (kind, _), obj in full.items():
    if kind == "Service":
        assert obj["spec"]["type"] == "ClusterIP"
    if kind == "Job":
        assert "helm.sh/hook" not in obj["metadata"].get("annotations", {})
print("PASS: enabled profile has ordinary bootstrap Jobs, internal Services and no app Secrets")

# The helper's closed schema rejects unsupported pretend-production controls;
# do not add a second parent implementation of these infrastructure settings.
for value in (
    "quickstart.openbao.mode=production",
    "quickstart.postgresql.persistence.enabled=true",
    "quickstart.postgresql.replicaCount=2",
    "quickstart.openbao.service.type=LoadBalancer",
):
    result = render(CHART, "-f", str(PROFILE), "--set", value)
    assert result.returncode != 0 and "Additional property" in result.stderr, value
print("PASS: unsupported production/persistence/replica/public exposure controls fail schema validation")
