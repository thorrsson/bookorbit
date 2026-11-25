#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$ROOT/scripts/azure/config.rb"
tmp=''
remote=''
target=''
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15)

cleanup() {
  status=$?
  if [[ -n "$remote" ]]; then
    if ! ssh "${ssh_options[@]}" "$target" "rm -f -- '$remote/.env' '$remote/docker-compose.yml' '$remote/compose.vm.yml' '$remote/Caddyfile' '$remote/vm-host.sh' && rmdir -- '$remote'" >&2; then
      echo "Remote deployment cleanup failed; remove the private staging directory: $remote" >&2
      [[ "$status" != 0 ]] || status=1
    fi
  fi
  if [[ -n "$tmp" ]]; then
    rm -f -- "$tmp/parameters.json" "$tmp/parameters-next.json" "$tmp/domains.json" "$tmp/.env" "$tmp/docker-compose.yml" "$tmp/compose.vm.yml" "$tmp/Caddyfile" "$tmp/vm-host.sh"
    rmdir -- "$tmp"
  fi
  exit "$status"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  bash scripts/azure/azure.sh init-env FILE
  bash scripts/azure/azure.sh plan|apply TARGET RESOURCE_GROUP PARAMETERS_FILE [RUNTIME_ENV] [--confirm-cutover]
  bash scripts/azure/azure.sh deploy-vm USER@HOST RUNTIME_ENV
  bash scripts/azure/azure.sh export-vm USER@HOST ARCHIVE.tar [--keep-stopped]
  bash scripts/azure/azure.sh bind-domain RESOURCE_GROUP APP_NAME RUNTIME_ENV [CNAME|HTTP]
Targets: vm, container-apps-platform, container-app
Azure operations require an explicit AZURE_SUBSCRIPTION_ID and an existing resource group.
SSH uses your agent/default keys and an already verified known_hosts entry.
EOF
}

check_target() {
  [[ "$target" =~ ^[a-z_][a-z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] ||
    { echo "Expected an SSH USER@HOST target." >&2; exit 1; }
}

command="${1:-help}"
shift || true
case "$command" in
  init-env)
    [[ $# == 1 ]] || { usage >&2; exit 1; }
    ruby "$config" init-env "$1"
    echo "Created owner-only runtime settings. Set the hostname and pinned image digests before deploying."
    ;;
  plan|apply)
    [[ $# -ge 3 && $# -le 5 ]] || { usage >&2; exit 1; }
    deployment="$1"; group="$2"; parameters="$3"; env_file="${4:--}"
    case "$deployment" in
      vm|container-apps-platform|container-app) ;;
      *) usage >&2; exit 1 ;;
    esac
    : "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID explicitly.}"
    tmp="$(mktemp -d)"
    ruby "$config" parameters "$deployment" "$parameters" "$env_file" > "$tmp/parameters.json"
    az account show --subscription "$AZURE_SUBSCRIPTION_ID" --only-show-errors --output none
    [[ "$(az group exists --subscription "$AZURE_SUBSCRIPTION_ID" --name "$group")" == true ]] ||
      { echo "Resource group must already exist in the selected subscription." >&2; exit 1; }
    if [[ "$deployment" == container-app ]]; then
      if [[ "$command" == apply && "${5:-}" != --confirm-cutover ]]; then
        echo "Stop the source writers and pass --confirm-cutover. See docs/AZURE.md." >&2
        exit 1
      fi
      app_name="$(jq -r '.parameters.name.value // "bookorbit"' "$tmp/parameters.json")"
      existing="$(az resource list --subscription "$AZURE_SUBSCRIPTION_ID" -g "$group" \
        --resource-type Microsoft.App/containerApps --name "$app_name" --query '[].name' -o tsv)"
      if [[ -n "$existing" ]]; then
        if [[ "$command" == apply ]]; then
          active="$(az containerapp revision list --subscription "$AZURE_SUBSCRIPTION_ID" -g "$group" -n "$app_name" \
            --query '[?properties.active].name' -o tsv)"
          [[ -z "$active" ]] || { echo "Deactivate ALL existing revisions before deploying; rolling revisions can overlap schedulers and migrations." >&2; exit 1; }
        fi
        az containerapp show --subscription "$AZURE_SUBSCRIPTION_ID" -g "$group" -n "$app_name" \
          --query properties.configuration.ingress.customDomains -o json > "$tmp/domains.json"
        ruby "$config" preserve-domains "$tmp/parameters.json" "$tmp/domains.json" > "$tmp/parameters-next.json"
        mv "$tmp/parameters-next.json" "$tmp/parameters.json"
      fi
    fi
    args=(--subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$group"
      --name "bookorbit-$deployment" --mode Incremental
      --template-file "$ROOT/infra/azure/$deployment.bicep" --parameters "@$tmp/parameters.json"
      --only-show-errors)
    if [[ "$command" == plan ]]; then
      az deployment group what-if "${args[@]}"
    else
      az deployment group create "${args[@]}" --query properties.outputs --output json
    fi
    ;;
  deploy-vm)
    [[ $# == 2 ]] || { usage >&2; exit 1; }
    target="$1"; env_file="$2"
    check_target
    url="$(ruby "$config" validate-env "$env_file")"
    ssh "${ssh_options[@]}" "$target" 'sudo cloud-init status --wait' >&2
    remote="$(ssh "${ssh_options[@]}" "$target" 'umask 077; mktemp -d /tmp/bookorbit.XXXXXXXXXX')"
    [[ "$remote" =~ ^/tmp/bookorbit\.[a-zA-Z0-9]+$ ]] ||
      { remote=''; echo "Invalid remote staging directory." >&2; exit 1; }
    tmp="$(mktemp -d)"
    cp "$env_file" "$tmp/.env"
    cp "$ROOT/docker-compose.yml" "$tmp/docker-compose.yml"
    cp "$ROOT/infra/azure/compose.vm.yml" "$tmp/compose.vm.yml"
    cp "$ROOT/infra/azure/Caddyfile" "$tmp/Caddyfile"
    cp "$ROOT/scripts/azure/vm-host.sh" "$tmp/vm-host.sh"
    tar -C "$tmp" -cf - . | ssh "${ssh_options[@]}" "$target" "tar -xf - -C '$remote'"
    ssh "${ssh_options[@]}" "$target" "sudo bash '$remote/vm-host.sh' deploy '$remote'"
    curl --fail --silent --show-error --retry 12 --retry-delay 10 --retry-all-errors --max-time 15 "$url/api/v1/health"
    printf '\nDeployment healthy at %s\n' "$url"
    ;;
  export-vm)
    [[ $# -ge 2 && $# -le 3 && ( $# == 2 || "$3" == --keep-stopped ) ]] || { usage >&2; exit 1; }
    target="$1"; archive="$2"; keep_stopped="${3:-}"
    check_target
    [[ ! -e "$archive" && ! -e "$archive.partial" ]] || { echo "Archive or partial archive already exists." >&2; exit 1; }
    if ! (set -o noclobber; ssh "${ssh_options[@]}" "$target" \
      "sudo /usr/local/sbin/bookorbit-vm export $keep_stopped" > "$archive.partial"); then
      echo "Export failed; no complete archive was published. Any $archive.partial is unverified and contains private data; inspect or remove it securely." >&2
      exit 1
    fi
    ln "$archive.partial" "$archive"
    rm -- "$archive.partial"
    echo "Created private archive: $archive. It contains credentials; store it encrypted and off the VM."
    ;;
  bind-domain)
    [[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 1; }
    group="$1"; app_name="$2"; env_file="$3"; method="${4:-CNAME}"
    [[ "$method" == CNAME || "$method" == HTTP ]] || { echo "Use CNAME for a subdomain or HTTP for an apex A record." >&2; exit 1; }
    [[ "$app_name" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ && "$app_name" != *--* ]] ||
      { echo "Invalid Container App name." >&2; exit 1; }
    : "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID explicitly.}"
    domain="$(ruby "$config" hostname "$env_file")"
    environment_id="$(az containerapp show --subscription "$AZURE_SUBSCRIPTION_ID" -g "$group" -n "$app_name" \
      --query properties.managedEnvironmentId -o tsv)"
    [[ -n "$environment_id" ]] || { echo "The Container App has no managed environment." >&2; exit 1; }
    az containerapp hostname add --subscription "$AZURE_SUBSCRIPTION_ID" -g "$group" -n "$app_name" \
      --hostname "$domain" --only-show-errors --output none
    az containerapp hostname bind --subscription "$AZURE_SUBSCRIPTION_ID" -g "$group" -n "$app_name" \
      --hostname "$domain" --environment "$environment_id" --validation-method "$method" --only-show-errors --output none
    curl --fail --silent --show-error --retry 12 --retry-delay 10 --retry-all-errors --max-time 15 "https://$domain/api/v1/health"
    printf '\nManaged certificate bound and HTTPS verified for %s\n' "$domain"
    ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 1 ;;
esac
