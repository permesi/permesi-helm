#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 1
fi

version="${1#v}"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
  sed -E -i.bak "s/^version: .*/version: ${version}/" "${file}"
  sed -E -i.bak "s/^appVersion: .*/appVersion: \"${version}\"/" "${file}"
  rm -f "${file}.bak"
done

values_file="charts/permesi-stack/values.yaml"
sed -E -i.bak "s/tag: \".*\" # managed-by-release-bot/tag: \"${version}\" # managed-by-release-bot/g" "${values_file}"
rm -f "${values_file}.bak"

echo "Bumped charts to ${version}"
