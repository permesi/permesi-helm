#!/usr/bin/env python3
"""Find the newest successfully recorded sandbox pair across both triggering repositories."""
import json
import re
import subprocess


def api(repo, path):
    return json.loads(subprocess.check_output(["gh", "api", f"repos/permesi/{repo}/{path}"]))


def recorded(repo, run, statuses):
    """Success survives a later failed or cancelled rerun of the same workflow."""
    kind = "App" if repo == "permesi-helm" else "Helm"
    pairs = []
    for status in statuses:
        match = re.fullmatch(r"containment/([0-9]+)/([1-9][0-9]*)", status["context"])
        if not match or int(match[1]) != run["id"] or int(match[2]) > run["run_attempt"]:
            continue
        url = run["html_url"] + "/attempts/" + match[2]
        peer = re.fullmatch(kind + r" ([0-9a-f]{40}), OCI artifact ([1-9][0-9]*)", status.get("description") or "")
        if (status["state"] == "success" and peer and status["target_url"] == url and
                status["creator"]["login"] == "github-actions[bot]"):
            app, helm = (peer[1], run["head_sha"]) if kind == "App" else (run["head_sha"], peer[1])
            pairs.append(dict(app=app, helm=helm, artifact_id=int(peer[2]), run=url,
                              run_id=run["id"], attempt=int(match[2])))
    return max(pairs, key=lambda item: item["attempt"], default=None)


def latest(repo, workflow):
    page = 1
    while True:
        runs = api(repo, f"actions/workflows/{workflow}/runs?branch=sandbox&per_page=100&page={page}")["workflow_runs"]
        for run in runs:
            pages = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp",
                f'repos/permesi/{repo}/commits/{run["head_sha"]}/statuses?per_page=100']))
            record = recorded(repo, run, (status for batch in pages for status in batch))
            if record:
                return record
        if len(runs) < 100:
            return None
        page += 1


def select(left, right):
    """Require non-regressing revisions in both repos, then prefer the newer run for identical pairs."""
    if not left or not right:
        return left or right
    progression = set()
    for key, repo in (("app", "permesi"), ("helm", "permesi-helm")):
        if left[key] != right[key]:
            progression.add(api(repo, f'compare/{left[key]}...{right[key]}')["status"])
    if not progression:
        return max((left, right), key=lambda r: (r["run_id"], r["attempt"]))
    if progression == {"ahead"}:
        return right
    if progression == {"behind"}:
        return left
    raise ValueError("qualified sandbox histories have diverged")


if __name__ == "__main__":
    result = select(latest("permesi", "build.yml"), latest("permesi-helm", "containment-ci.yml"))
    if not result:
        raise SystemExit("no successful pair recorded")
    print(json.dumps(result, indent=2))
