#!/usr/bin/env bash
# Bump chart versions, appVersion and managed image identities for a release.
#
# Usage:
#   bump-release.sh [--chart-version X.Y.Z] [--tag-only] <version>
#   bump-release.sh [--chart-version X.Y.Z] --digest permesi=sha256:<64 hex> \
#       --digest genesis=sha256:<64 hex> --digest web=sha256:<64 hex> <version>
#   bump-release.sh --chart-only <chart-version>
#
# App release (default): sets appVersion and every managed image tag to
# <version> in the standalone and umbrella values. With --digest (all three
# services required) the matching digests are written too; without it (tag-only,
# also selectable explicitly with --tag-only) every managed digest is cleared so
# a previous digest never pins a new tag.
#
# Chart version: --chart-version, otherwise <version> when that advances the
# current chart version, otherwise the next patch of the current chart version.
# A chart version is never allowed to regress or repeat.
#
# Chart-only release: bumps chart versions (and umbrella dependency versions)
# only; appVersion, tags and digests are left unchanged.
#
# All inputs are validated before any file is modified; edits are staged and
# only moved into place once every file has been rewritten successfully.
set -euo pipefail

services=(permesi genesis web)
semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
digest_re='^sha256:[0-9a-f]{64}$'

usage() {
    sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

die() {
    echo "$*" >&2
    exit 1
}

# Prints -1, 0 or 1 comparing two X.Y.Z versions.
semver_cmp() {
    local -a a b
    local i x y
    local LC_ALL=C
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        # Strip leading zeros and compare decimal strings without integer
        # overflow, including versions supplied by an external release event.
        x="${a[i]}"; x="${x#"${x%%[!0]*}"}"; x="${x:-0}"
        y="${b[i]}"; y="${y#"${y%%[!0]*}"}"; y="${y:-0}"
        if [[ ${#x} -lt ${#y} ]]; then echo -1; return; fi
        if [[ ${#x} -gt ${#y} ]]; then echo 1; return; fi
        if [[ "${x}" < "${y}" ]]; then echo -1; return; fi
        if [[ "${x}" > "${y}" ]]; then echo 1; return; fi
    done
    echo 0
}

next_patch() {
    local prefix="${1%.*}" patch="${1##*.}" result="" digit carry=1 i
    for ((i = ${#patch} - 1; i >= 0; i--)); do
        digit=$((10#${patch:i:1} + carry))
        result="$((digit % 10))${result}"
        carry=$((digit / 10))
    done
    [[ ${carry} -eq 0 ]] || result="1${result}"
    echo "${prefix}.${result}"
}

mode="app"
chart_version=""
tag_only_flag=0
declare -A digests=()
positional=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chart-version)
            [[ $# -ge 2 ]] || usage
            [[ -z "${chart_version}" ]] || die "--chart-version may only be supplied once"
            [[ "${2#v}" =~ ${semver_re} ]] || die "invalid chart version '$2', expected X.Y.Z or vX.Y.Z"
            chart_version="${2#v}"
            shift 2
            ;;
        --digest)
            [[ $# -ge 2 ]] || usage
            entry="$2"
            svc="${entry%%=*}"
            value="${entry#*=}"
            [[ "${entry}" == *=* ]] || die "invalid --digest '${entry}', expected <service>=sha256:<64 hex>"
            case " ${services[*]} " in
                *" ${svc} "*) ;;
                *) die "invalid --digest service '${svc}', expected one of: ${services[*]}" ;;
            esac
            [[ -z "${digests[${svc}]+set}" ]] || die "duplicate --digest for '${svc}'"
            [[ "${value}" =~ ${digest_re} ]] || die "invalid digest for '${svc}', expected sha256:<64 lowercase hex>"
            digests[${svc}]="${value}"
            shift 2
            ;;
        --tag-only)
            tag_only_flag=1
            shift
            ;;
        --chart-only)
            mode="chart"
            shift
            ;;
        -h | --help)
            usage
            ;;
        --*)
            die "unknown option '$1'"
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

[[ ${#positional[@]} -eq 1 ]] || usage

version="${positional[0]#v}"
if [[ ! "$version" =~ ${semver_re} ]]; then
    die "invalid version '${positional[0]}', expected X.Y.Z or vX.Y.Z"
fi

stack_chart="charts/permesi-stack/Chart.yaml"
chart_files=(
    "charts/permesi/Chart.yaml"
    "charts/genesis/Chart.yaml"
    "charts/web/Chart.yaml"
    "${stack_chart}"
)

current_chart_version=""
for file in "${chart_files[@]}"; do
    [[ -f "${file}" ]] || die "missing ${file}"
    v="$(awk '/^version:/{print $2; exit}' "${file}")"
    [[ "${v}" =~ ${semver_re} ]] || die "${file} has invalid version '${v}'"
    if [[ -z "${current_chart_version}" || "$(semver_cmp "${v}" "${current_chart_version}")" == 1 ]]; then
        current_chart_version="${v}"
    fi
done

if [[ "${mode}" == "chart" ]]; then
    [[ -z "${chart_version}" ]] || die "--chart-version cannot be combined with --chart-only (pass the chart version as the argument)"
    [[ ${#digests[@]} -eq 0 && ${tag_only_flag} -eq 0 ]] || die "--digest/--tag-only cannot be combined with --chart-only"
    chart_version="${version}"
else
    if [[ ${#digests[@]} -gt 0 ]]; then
        [[ ${tag_only_flag} -eq 0 ]] || die "--tag-only cannot be combined with --digest"
        for svc in "${services[@]}"; do
            [[ -n "${digests[${svc}]+set}" ]] || die "missing --digest for '${svc}': provide all of ${services[*]} or none (tag-only)"
        done
    fi
    if [[ -z "${chart_version}" ]]; then
        if [[ "$(semver_cmp "${version}" "${current_chart_version}")" == 1 ]]; then
            chart_version="${version}"
        else
            chart_version="$(next_patch "${current_chart_version}")"
        fi
    fi
fi

[[ "${chart_version}" =~ ${semver_re} ]] || die "invalid chart version '${chart_version}', expected X.Y.Z or vX.Y.Z"
if [[ "$(semver_cmp "${chart_version}" "${current_chart_version}")" != 1 ]]; then
    die "chart version ${chart_version} must be greater than the current chart version ${current_chart_version}"
fi

values_files=(
    "charts/permesi/values.yaml"
    "charts/genesis/values.yaml"
    "charts/web/values.yaml"
)
stack_values_file="charts/permesi-stack/values.yaml"
readme_files=(
    "README.md"
    "charts/permesi/README.md"
    "charts/genesis/README.md"
    "charts/web/README.md"
    "charts/permesi-stack/README.md"
)

# Stage every rewrite in a scratch directory; nothing in the tree changes until
# all of them succeed.
stage_dir="$(mktemp -d)"
trap 'rm -rf -- "${stage_dir}"' EXIT
staged=()

# Staging path of a tree file.
stage() {
    printf '%s/%s\n' "${stage_dir}" "${1//\//__}"
}

for file in "${chart_files[@]}" "${values_files[@]}" "${stack_values_file}" "${readme_files[@]}"; do
    [[ -f "${file}" ]] || continue
    cp -- "${file}" "$(stage "${file}")"
    staged+=("${file}")
done

for file in "${chart_files[@]}"; do
    target="$(stage "${file}")"
    sed -E -i "s/^version: .*/version: ${chart_version}/" "${target}"
    if [[ "${mode}" == "app" ]]; then
        # Keep appVersion yamlfix-friendly (no forced quotes).
        sed -E -i "s/^appVersion: .*/appVersion: ${version}/" "${target}"
    fi
done

target="$(stage "${stack_chart}")"
awk -v version="${chart_version}" '
  /^  - name: (permesi|genesis|web)$/ { in_dep = 1; print; next }
  in_dep == 1 && /^    version:/ { print "    version: " version; in_dep = 0; next }
  { print }
' "${target}" > "${target}.tmp"
mv "${target}.tmp" "${target}"

if [[ "${mode}" == "app" ]]; then
    # Standalone charts: rewrite tag and digest of the top-level `image:` block
    # only (the Vault Agent image is pinned independently).
    for i in "${!values_files[@]}"; do
        file="${values_files[i]}"
        svc="${services[i]}"
        target="$(stage "${file}")"
        awk -v version="${version}" -v digest="${digests[${svc}]:-}" '
          /^image:[[:space:]]*$/ { in_image = 1; print; next }
          in_image == 1 && /^[^[:space:]#]/ { in_image = 0 }
          in_image == 1 && /^  tag:/ { print "  tag: " version; tag++; next }
          in_image == 1 && /^  digest:/ { print "  digest: \"" digest "\""; dig++; next }
          { print }
          END { if (tag != 1 || dig != 1) exit 3 }
        ' "${target}" > "${target}.tmp" || die "${file}: expected exactly one image.tag and one image.digest"
        mv "${target}.tmp" "${target}"
    done

    # Umbrella: rewrite the managed tag/digest lines inside each service block.
    target="$(stage "${stack_values_file}")"
    awk -v version="${version}" \
        -v d_permesi="${digests[permesi]:-}" \
        -v d_genesis="${digests[genesis]:-}" \
        -v d_web="${digests[web]:-}" '
      BEGIN { want["permesi"] = d_permesi; want["genesis"] = d_genesis; want["web"] = d_web }
      /^[^[:space:]#][^:]*:/ { svc = $0; sub(/:.*/, "", svc) }
      /^    tag:.*# managed-by-release-bot[[:space:]]*$/ {
        if (!(svc in want)) exit 4
        print "    tag: " version "  # managed-by-release-bot"; tag[svc]++; next
      }
      /^    digest:.*# managed-by-release-bot[[:space:]]*$/ {
        if (!(svc in want)) exit 4
        print "    digest: \"" want[svc] "\"  # managed-by-release-bot"; dig[svc]++; next
      }
      { print }
      END { for (s in want) if (tag[s] != 1 || dig[s] != 1) exit 3 }
    ' "${target}" > "${target}.tmp" || die "${stack_values_file}: expected one managed tag and digest line per service"
    mv "${target}.tmp" "${target}"
fi

# Keep chart install `--version X.Y.Z` references in the docs in sync.
for file in "${readme_files[@]}"; do
    [[ -f "${file}" ]] || continue
    target="$(stage "${file}")"
    sed -E -i "s/(--version[[:space:]]+)[0-9]+\.[0-9]+\.[0-9]+/\1${chart_version}/g" "${target}"
done

for file in "${staged[@]}"; do
    target="$(stage "${file}")"
    cmp -s -- "${target}" "${file}" || cat -- "${target}" > "${file}"
done

if [[ "${mode}" == "chart" ]]; then
    echo "Bumped chart versions to ${chart_version} (images unchanged)"
elif [[ ${#digests[@]} -gt 0 ]]; then
    echo "Bumped charts to ${chart_version}, app ${version} pinned by digest"
else
    echo "Bumped charts to ${chart_version}, app ${version} (tag-only, digests cleared)"
fi
