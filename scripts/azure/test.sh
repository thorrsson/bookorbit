#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
for tool in bicep ruby docker jq; do
  command -v "$tool" >/dev/null || { echo "Missing validation prerequisite: $tool" >&2; exit 1; }
done
docker compose version >/dev/null
bash -n scripts/azure/azure.sh scripts/azure/vm-host.sh scripts/azure/test.sh infra/azure/bootstrap-vm.sh
ruby -c scripts/azure/config.rb

tmp="$(mktemp -d)"
trap 'rm -f -- "$tmp/vm.json" "$tmp/container-apps-platform.json" "$tmp/container-app.json"; rmdir -- "$tmp"' EXIT
for target in vm container-apps-platform container-app; do
  bicep build "infra/azure/$target.bicep" --outfile "$tmp/$target.json"
done
BICEP_BUILD_DIR="$tmp" ruby scripts/azure/deployment.test.rb
