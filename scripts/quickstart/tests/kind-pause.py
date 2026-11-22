"""Pause a named test container in an owned KinD node, with an independent resume timer."""
from contextlib import contextmanager
import json
import re
import subprocess


@contextmanager
def paused(kube, pod, container, seconds):
    """Freeze just this container so established connections also stop serving."""
    def get(kind, name):
        return json.loads(subprocess.check_output(kube + ["get", kind, name, "-o", "json"]))
    info = get("pod", pod)
    node = info["spec"]["nodeName"]
    provider = get("node", node)["spec"]["providerID"].split("/")
    if (len(provider) != 5 or provider[:2] != ["kind:", ""] or provider[2] not in ("podman", "docker")
            or provider[-1] != node or not 1 <= seconds <= 75):
        raise ValueError("pause requires an owned KinD container and a bounded interval")
    statuses = info["status"].get("initContainerStatuses", []) + info["status"]["containerStatuses"]
    target = next(c["containerID"] for c in statuses if c["name"] == container)
    if not re.fullmatch("containerd://[0-9a-f]{64}", target):
        raise ValueError("expected a running containerd task")
    command = """set -eu
resume() { ctr -n k8s.io tasks resume "$1" >/dev/null 2>&1 || :; }
trap 'resume "$1"' EXIT HUP INT TERM
ctr -n k8s.io tasks pause "$1"
echo paused
sleep "$2"
"""
    with subprocess.Popen([provider[2], "exec", node, "sh", "-c", command, "sh",
                           target.removeprefix("containerd://"), str(seconds)],
                          stdout=subprocess.PIPE, text=True) as watchdog:
        try:
            if watchdog.stdout.readline().strip() != "paused":
                raise RuntimeError("KinD runtime failed to pause the selected test container")
            yield
        finally:
            watchdog.wait(timeout=seconds + 15)
            if watchdog.returncode:
                raise RuntimeError("KinD runtime pause watchdog failed")
