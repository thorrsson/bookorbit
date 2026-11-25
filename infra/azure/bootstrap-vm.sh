#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends azure-vm-utils ca-certificates curl nfs-common rsync
udevadm trigger --subsystem-match=block
udevadm settle

device=
for attempt in $(seq 1 120); do
  for link in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
    [[ -b "$link" ]] && device="$(readlink -f "$link")" && break 2
  done
  sleep 2
done
[[ -n "$device" ]] || { echo "Azure data disk LUN 0 is missing." >&2; exit 1; }

if filesystem="$(blkid -p -s TYPE -o value "$device")"; then
  [[ "$filesystem" == ext4 ]] || { echo "Refusing to overwrite an existing non-ext4 disk." >&2; exit 1; }
else
  status=$?
  [[ "$status" == 2 && -z "$(wipefs --no-act --noheadings --output TYPE "$device")" ]] ||
    { echo "Disk is not blank. Refusing to format it." >&2; exit 1; }
  mkfs.ext4 -L bookorbit-data "$device"
fi

uuid="$(blkid -s UUID -o value "$device")"
mkdir -p /srv/bookorbit
if ! grep -Fq "UUID=$uuid /srv/bookorbit " /etc/fstab; then
  if grep -Eq '[[:space:]]/srv/bookorbit[[:space:]]' /etc/fstab; then
    echo "An unexpected filesystem already owns /srv/bookorbit." >&2
    exit 1
  fi
  printf 'UUID=%s /srv/bookorbit ext4 defaults 0 2\n' "$uuid" >> /etc/fstab
fi
mountpoint -q /srv/bookorbit || mount /srv/bookorbit
[[ "$(findmnt -n -o UUID --target /srv/bookorbit)" == "$uuid" ]] ||
  { echo "Unexpected filesystem mounted at /srv/bookorbit." >&2; exit 1; }

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/bookorbit-storage.conf <<'EOF'
[Unit]
RequiresMountsFor=/srv/bookorbit
ConditionPathIsMountPoint=/srv/bookorbit
EOF

install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 5 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker compose version
install -d -m 0700 /srv/bookorbit/releases /srv/bookorbit/backups
install -d /srv/bookorbit/state/{books,app,postgres,caddy-data,caddy-config}
systemctl daemon-reload
systemctl enable --now docker
