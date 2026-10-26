#!/usr/bin/env bash
# Resolve and validate the release described by the triggering GitHub event.
#
# Used by .github/workflows/release-bump-pr.yml. Reads only the event JSON
# (GITHUB_EVENT_PATH) through jq; no event value is ever evaluated as shell.
#
# Env:
#   GITHUB_EVENT_NAME  repository_dispatch | workflow_dispatch
#   GITHUB_EVENT_PATH  path to the event JSON
#   GITHUB_OUTPUT      file receiving key=value outputs (default: stdout)
#   GITHUB_ACTOR, GITHUB_SHA, GITHUB_REF  recorded as the source of manual runs
#
# repository_dispatch (from permesi/permesi .github/actions/dispatch-helm):
#   client_payload.{version, source_repo, source_sha, source_tag,
#                   images.<permesi|genesis|web>.{repository, tag, digest}}
#   Every image must be ghcr.io/permesi/<service> tagged with the version. The
#   digests must be all valid, or all empty with client_payload.tag_only=true.
#
# workflow_dispatch inputs:
#   version, chart_version (optional), permesi_digest, genesis_digest,
#   web_digest, tag_only. tag_only=true requires all digests empty; otherwise
#   all three digests are required.
#
# Outputs: version, chart_version, mode (digest|tag-only), permesi_digest,
# genesis_digest, web_digest, source_repo, source_sha, source_tag, source_actor.
set -euo pipefail

services=(permesi genesis web)
semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
digest_re='^sha256:[0-9a-f]{64}$'
sha_re='^[0-9a-f]{40}$'
expected_source_repo="permesi/permesi"

die() {
    echo "release-event: $*" >&2
    exit 1
}

event_path="${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
[[ -f "${event_path}" ]] || die "event file not found"
jq -e 'type == "object"' "${event_path}" >/dev/null 2>&1 || die "event is not a JSON object"

# Prints a single-line string at a jq path; empty when absent/null.
field() {
    local value
    value="$(jq -r --arg p "$1" '
      getpath($p | split(".")) as $v
      | if $v == null then ""
        elif ($v | type) != "string" then error("not a string")
        elif ($v | test("[\u0000-\u001f\u007f]")) then error("control character")
        else $v end
    ' "${event_path}" 2>/dev/null)" || die "$1 must be a single-line string"
    printf '%s' "${value}"
}

declare -A digest=()
chart_version=""
source_actor="${GITHUB_ACTOR:-}"

case "${GITHUB_EVENT_NAME:-}" in
    repository_dispatch)
        raw_version="$(field client_payload.version)"
        source_repo="$(field client_payload.source_repo)"
        source_sha="$(field client_payload.source_sha)"
        source_tag="$(field client_payload.source_tag)"

        version="${raw_version#v}"
        [[ "${version}" =~ ${semver_re} ]] || die "client_payload.version must be X.Y.Z or vX.Y.Z"
        [[ "${source_repo}" == "${expected_source_repo}" ]] || die "client_payload.source_repo must be ${expected_source_repo}"
        [[ "${source_sha}" =~ ${sha_re} ]] || die "client_payload.source_sha must be a 40-hex commit SHA"
        [[ "${source_tag#v}" == "${version}" ]] || die "client_payload.source_tag must match the version"
        tag_only="$(jq -r '.client_payload.tag_only // false | tostring' "${event_path}")"
        [[ "${tag_only}" == "true" || "${tag_only}" == "false" ]] || die "client_payload.tag_only must be a boolean"

        jq -e '.client_payload.images | type == "object"' "${event_path}" >/dev/null 2>&1 \
            || die "client_payload.images is required (repository/tag/digest per service)"

        for svc in "${services[@]}"; do
            jq -e --arg svc "${svc}" '.client_payload.images[$svc].digest | type == "string"' \
                "${event_path}" >/dev/null 2>&1 || die "images.${svc}.digest must be a string (empty for tag-only)"
            repo="$(field "client_payload.images.${svc}.repository")"
            tag="$(field "client_payload.images.${svc}.tag")"
            digest[${svc}]="$(field "client_payload.images.${svc}.digest")"
            [[ "${repo}" == "ghcr.io/permesi/${svc}" ]] || die "images.${svc}.repository must be ghcr.io/permesi/${svc}"
            [[ "${tag}" == "${version}" ]] || die "images.${svc}.tag must match the version"
        done
        ;;
    workflow_dispatch)
        raw_version="$(field inputs.version)"
        chart_version="$(field inputs.chart_version)"
        version="${raw_version#v}"
        [[ "${version}" =~ ${semver_re} ]] || die "inputs.version must be X.Y.Z or vX.Y.Z"
        chart_version="${chart_version#v}"
        [[ -z "${chart_version}" || "${chart_version}" =~ ${semver_re} ]] || die "inputs.chart_version must be X.Y.Z, vX.Y.Z or empty"
        for svc in "${services[@]}"; do
            digest[${svc}]="$(field "inputs.${svc}_digest")"
        done
        tag_only="$(jq -r '.inputs.tag_only // false | tostring' "${event_path}")"
        [[ "${tag_only}" == "true" || "${tag_only}" == "false" ]] || die "inputs.tag_only must be a boolean"
        source_repo="manual"
        source_sha="${GITHUB_SHA:-}"
        source_tag="${GITHUB_REF:-}"
        [[ -z "${source_sha}" || "${source_sha}" =~ ${sha_re} ]] || die "GITHUB_SHA must be a 40-hex commit SHA"
        [[ "${source_tag}" != *$'\n'* && "${source_tag}" != *$'\r'* ]] || die "GITHUB_REF must be a single line"
        ;;
    *)
        die "unsupported event '${GITHUB_EVENT_NAME:-}'"
        ;;
esac

[[ "${source_actor}" =~ ^[A-Za-z0-9-]*(\[bot\])?$ ]] || die "GITHUB_ACTOR has unexpected characters"

set_count=0
for svc in "${services[@]}"; do
    if [[ -n "${digest[${svc}]}" ]]; then
        [[ "${digest[${svc}]}" =~ ${digest_re} ]] || die "${svc} digest must be sha256:<64 lowercase hex>"
        set_count=$((set_count + 1))
    fi
done

if [[ ${set_count} -eq ${#services[@]} ]]; then
    mode="digest"
elif [[ ${set_count} -eq 0 ]]; then
    mode="tag-only"
else
    die "partial digests: provide all of ${services[*]} or none"
fi

if [[ "${tag_only}" == "true" && "${mode}" != "tag-only" ]]; then
    die "tag_only=true cannot be combined with digests"
fi
if [[ "${tag_only}" != "true" && "${mode}" != "digest" ]]; then
    die "provide all three digests or set tag_only=true to acknowledge a tag-only release"
fi

{
    echo "version=${version}"
    echo "chart_version=${chart_version}"
    echo "mode=${mode}"
    for svc in "${services[@]}"; do
        echo "${svc}_digest=${digest[${svc}]}"
    done
    echo "source_repo=${source_repo}"
    echo "source_sha=${source_sha}"
    echo "source_tag=${source_tag}"
    echo "source_actor=${source_actor}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
