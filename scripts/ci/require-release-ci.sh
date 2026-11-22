#!/usr/bin/env bash
# Authorize publication only for the exact chart revision that passed main CI.
set -euo pipefail
sha="$(git rev-parse HEAD)"
main="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq .object.sha)"
[[ "$sha" == "$main" ]] || { echo 'Release target is no longer main' >&2; exit 1; }
gh api "repos/$GITHUB_REPOSITORY/actions/workflows/charts-ci.yml/runs?branch=main&head_sha=$sha&status=success" |
  jq -e --arg sha "$sha" 'any(.workflow_runs[]; .head_sha == $sha and .head_branch == "main" and
    .conclusion == "success" and (.event == "push" or .event == "workflow_dispatch"))' >/dev/null
python3 -m pip install PyYAML==6.0.3
python3 scripts/ci/check-release-fixture.py
