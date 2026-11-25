#!/usr/bin/env bash
set -euo pipefail
umask 077

root=/srv/bookorbit
[[ "$(id -u)" == 0 ]] || { echo "Run this command with sudo." >&2; exit 1; }
mountpoint -q "$root" || { echo "The persistent data disk is not mounted. Refusing to write to the OS disk." >&2; exit 1; }
exec 9>"$root/.deployment.lock"
flock -n 9 || { echo "Another deployment or export is running." >&2; exit 1; }

compose() {
  local release="$1"
  shift
  docker compose --project-name bookorbit --project-directory "$release" --env-file "$release/.env" \
    -f "$release/docker-compose.yml" -f "$release/compose.vm.yml" "$@"
}

dump_database() {
  local release="$1" destination="$2"
  if ! compose "$release" exec -T postgres sh -c 'exec pg_dump --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --format=custom' > "$destination.partial"; then
    return 1
  fi
  mv "$destination.partial" "$destination"
}

case "${1:-}" in
  deploy)
    stage="${2:-}"
    [[ "$stage" =~ ^/tmp/bookorbit\.[a-zA-Z0-9]+$ && -f "$stage/.env" ]] ||
      { echo "Expected a private deployment staging directory." >&2; exit 1; }
    previous=''
    if [[ -L "$root/current" ]]; then
      previous="$(readlink -f "$root/current")"
      critical='^(POSTGRES_USER|POSTGRES_DB|POSTGRES_PASSWORD|JWT_SECRET|EMAIL_ENCRYPTION_KEY|MIGRATION_ENCRYPTION_KEY|BOOK_REQUEST_ENCRYPTION_KEY)='
      if ! cmp -s <(grep -E "$critical" "$previous/.env" | grep -v '=$' | sort) \
        <(grep -E "$critical" "$stage/.env" | grep -v '=$' | sort); then
        echo "Database credentials or application encryption/signing keys changed. Use the existing settings; rotate keys as a separate operation." >&2
        exit 1
      fi
    fi
    release="$root/releases/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    install -d -m 0700 "$release"
    for file in .env docker-compose.yml compose.vm.yml Caddyfile; do
      install -m 0600 "$stage/$file" "$release/$file"
    done
    if [[ -z "$previous" ]]; then
      uid="$(awk -F= '$1 == "PUID" { print $2 }' "$release/.env")"
      gid="$(awk -F= '$1 == "PGID" { print $2 }' "$release/.env")"
      chown "${uid:-1000}:${gid:-1000}" "$root/state/books"
    fi
    compose "$release" config --quiet
    compose "$release" pull >&2
    if [[ -n "$previous" ]]; then
      backup="$root/backups/predeploy-$(basename "$release")"
      install -d -m 0700 "$backup"
      resume=false
      services="$(compose "$previous" ps --status running --services)"
      if grep -qx app <<< "$services"; then
        resume=true
        compose "$previous" stop --timeout 60 app >&2
      fi
      if ! dump_database "$previous" "$backup/database.dump"; then
        echo "Pre-deploy database backup failed. No migration was started." >&2
        if [[ "$resume" == true ]]; then compose "$previous" start app >&2; fi
        exit 1
      fi
      install -m 0600 "$previous/.env" "$backup/.env"
      printf '%s\n' "$previous" > "$backup/previous-release"
      echo "Pre-deploy database backup: $backup" >&2
    fi
    if ! compose "$release" up -d --wait --wait-timeout 1800; then
      echo "Deployment failed. Migrations may have run; do NOT automatically roll back the image. Restore the pre-deploy database before a schema rollback. Failed release: $release" >&2
      compose "$release" stop --timeout 60 app >&2
      exit 1
    fi
    ln -s "$release" "$root/current.next"
    mv -Tf "$root/current.next" "$root/current"
    install -m 0755 "$stage/vm-host.sh" /usr/local/sbin/bookorbit-vm
    echo "Installed release: $release" >&2
    ;;
  export)
    [[ $# == 1 || ( $# == 2 && "$2" == --keep-stopped ) ]] ||
      { echo "Usage: bookorbit-vm export [--keep-stopped]" >&2; exit 1; }
    release="$(readlink -f "$root/current")"
    snapshot="$(mktemp -d "$root/backups/export.XXXXXXXXXX")"
    resume=false
    finish_export() {
      status=$?
      trap - EXIT
      rm -f -- "$snapshot/database.dump" "$snapshot/database.dump.partial"
      rmdir -- "$snapshot"
      if [[ "$resume" == true ]]; then
        if ! compose "$release" start app >&2; then
          echo "Failed to resume the source application after export." >&2
          status=1
        fi
      fi
      exit "$status"
    }
    trap finish_export EXIT
    services="$(compose "$release" ps --status running --services)"
    if grep -qx app <<< "$services"; then
      [[ "${2:-}" == --keep-stopped ]] || resume=true
      compose "$release" stop --timeout 60 app >&2
    fi
    dump_database "$release" "$snapshot/database.dump"
    # Stream media rather than duplicating a potentially multi-terabyte library on disk.
    tar -C "$root/state" -cf - books app caddy-data caddy-config \
      -C "$snapshot" database.dump \
      -C "$release" .env docker-compose.yml compose.vm.yml Caddyfile
    if [[ "${2:-}" == --keep-stopped ]]; then echo "Source app remains stopped for cutover." >&2; fi
    ;;
  *)
    echo "Usage: bookorbit-vm deploy STAGING_DIRECTORY | export [--keep-stopped]" >&2
    exit 1
    ;;
esac
