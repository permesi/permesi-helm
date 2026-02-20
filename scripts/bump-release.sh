#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version>" >&2
    exit 1
fi

version="${1#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid version '${1}', expected X.Y.Z or vX.Y.Z" >&2
    exit 1
fi

chart_files=(
    "charts/permesi/Chart.yaml"
    "charts/genesis/Chart.yaml"
    "charts/web/Chart.yaml"
    "charts/permesi-stack/Chart.yaml"
)

for file in "${chart_files[@]}"; do
    sed -E -i.bak "s/^version: .*/version: ${version}/" "$file"
    # Keep appVersion yamlfix-friendly (no forced quotes).
    sed -E -i.bak "s/^appVersion: .*/appVersion: ${version}/" "$file"
    rm -f "${file}.bak"
done

stack_chart="charts/permesi-stack/Chart.yaml"
awk -v version="${version}" '
  /^  - name: (permesi|genesis|web)$/ { in_dep = 1; print; next }
  in_dep == 1 && /^    version:/ { print "    version: " version; in_dep = 0; next }
  { print }
' "${stack_chart}" > "${stack_chart}.tmp"
mv "${stack_chart}.tmp" "${stack_chart}"

values_file="charts/permesi-stack/values.yaml"
# Update managed tags whether current value is quoted or unquoted.
sed -E -i.bak "s|^(\s*tag:\s*)\"?[^\"#]+\"?\s*# managed-by-release-bot\s*$|\1${version}  # managed-by-release-bot|" "$values_file"
rm -f "${values_file}.bak"

echo "Bumped charts to ${version}"
