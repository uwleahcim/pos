#!/usr/bin/env bash
# Turn a fresh Ubuntu (22.04 or newer) or Debian (12 or newer) mini PC into a POS hub.
#
#   sudo ./infra/hub/bootstrap.sh --name pos-hub1 [--lan 192.168.10.0/24] [--ssh-from 192.168.10.0/24]
#
# Run it from a clone of the repository. It is safe to run again: every step only does what is missing.
set -euo pipefail

HUB_NAME="pos-hub1"
LAN=""
SSH_FROM=""
ADMIN="${SUDO_USER:-}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POS_HOME="/opt/pos"
REBOOT_AT="04:30"

usage() {
  sed -n '2,7p' "$0"
  echo "  --name HUB_NAME        hostname of this hub (pos-hub1)"
  echo "  --lan CIDR         the POS network; detected from the default route when omitted"
  echo "  --ssh-from CIDR    where SSH may come from; the LAN when omitted"
  echo "  --admin USER       user added to the docker group; the sudo caller when omitted"
  echo "  --src DIR          the repository clone to deploy; this script's own clone when omitted"
  echo "  --reboot-at HH:MM  nightly window for security updates that need a reboot (04:30)"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) HUB_NAME="$2"; shift 2 ;;
    --lan) LAN="$2"; shift 2 ;;
    --ssh-from) SSH_FROM="$2"; shift 2 ;;
    --admin) ADMIN="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    --reboot-at) REBOOT_AT="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
# shellcheck disable=SC1091
. /etc/os-release
major="${VERSION_ID%%.*}"
case "${ID:-}" in
  ubuntu) [[ ${major:-0} -ge 22 ]] || die "Ubuntu 22.04 or newer needed (this is ${PRETTY_NAME:-unknown})" ;;
  debian) [[ ${major:-0} -ge 12 ]] || die "Debian 12 or newer needed (this is ${PRETTY_NAME:-unknown})" ;;
  *) die "supported: Ubuntu 22.04 or newer, Debian 12 or newer (this is ${PRETTY_NAME:-unknown})" ;;
esac
[[ -f "$SRC/backend/pyproject.toml" ]] || die "no repository at $SRC; run from a clone or pass --src"

if [[ -z "$LAN" ]]; then
  iface=$(ip -o -4 route show default | awk '{print $5; exit}')
  [[ -n "$iface" ]] || die "no default route; connect the wired network first or pass --lan"
  addr=$(ip -o -4 addr show dev "$iface" | awk '{print $4; exit}')
  LAN=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$addr")
fi
SSH_FROM="${SSH_FROM:-$LAN}"
mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
[[ $mem_mb -ge 3500 ]] || echo "warning: ${mem_mb} MB of RAM; 8 GB is the recommended size" >&2

log "Hostname $HUB_NAME"
hostnamectl set-hostname "$HUB_NAME"
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  # Ubuntu Server's cloud-init puts the installer's hostname back on every boot unless told not to
  echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-pos-hub.cfg
fi
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $HUB_NAME/" /etc/hosts
else
  echo "127.0.1.1 $HUB_NAME" >> /etc/hosts
fi

log "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg git jq openssl ufw chrony unattended-upgrades \
  avahi-daemon openssh-server lm-sensors

if ! command -v docker > /dev/null; then
  # Docker's own repository when it knows this release; otherwise the distribution's packages, which lag
  # a little but work the same (a brand-new Ubuntu release is not in Docker's repository for a while).
  if curl -fsSIL --max-time 20 "https://download.docker.com/linux/$ID/dists/$VERSION_CODENAME/Release" > /dev/null 2>&1; then
    log "Docker from Docker's repository ($VERSION_CODENAME)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    log "Docker from the $PRETTY_NAME packages (Docker's repository has no $VERSION_CODENAME yet)"
    apt-get install -y -q docker.io docker-buildx docker-compose-v2
  fi
fi
systemctl enable --now docker
docker compose version > /dev/null 2>&1 || die "the docker compose plugin is missing"
if [[ -n "$ADMIN" ]] && id "$ADMIN" > /dev/null 2>&1; then
  usermod -aG docker "$ADMIN"
fi

log "Time: this hub serves the clock to the POS network ($LAN), even without internet"
install -d /etc/chrony/conf.d
cat > /etc/chrony/conf.d/pos-hub.conf <<CHRONY
allow $LAN
local stratum 10
CHRONY
systemctl enable --now chrony
systemctl restart chrony

log "Security updates install themselves; a reboot, if one is needed, happens at $REBOOT_AT"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<APT
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
cat > /etc/apt/apt.conf.d/52pos-hub <<APT
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_AT";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
APT

log "Firewall: SSH from $SSH_FROM; the API, time and discovery from $LAN; nothing else"
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow from "$SSH_FROM" to any port 22 proto tcp > /dev/null
ufw allow from "$LAN" to any port 8000 proto tcp > /dev/null
ufw allow from "$LAN" to any port 123 proto udp > /dev/null
ufw allow from "$LAN" to any port 5353 proto udp > /dev/null
ufw --force enable > /dev/null
systemctl enable --now avahi-daemon

log "POS services in $POS_HOME"
install -d -m 0750 "$POS_HOME"
if [[ ! -f "$POS_HOME/.env" ]]; then
  (
    umask 077
    printf 'POSTGRES_PASSWORD=%s\nPOS_NODE=%s\n' "$(openssl rand -hex 24)" "$HUB_NAME" > "$POS_HOME/.env"
  )
fi
sed -i -E "s/^POS_NODE=.*/POS_NODE=$HUB_NAME/" "$POS_HOME/.env"
ln -sfn "$SRC" "$POS_HOME/src"
install -m 0755 "$SRC/infra/hub/hubctl" /usr/local/bin/hubctl
# Built with docker build, not compose: the new bake builder refuses a build context behind a symlink
docker build -t pos-backend:local "$SRC/backend"
compose() {
  docker compose --project-directory "$POS_HOME" -f "$POS_HOME/src/infra/hub/docker-compose.yml" "$@"
}
compose up -d --remove-orphans

log "Waiting for the API"
ok=""
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8000/health > /dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
[[ -n "$ok" ]] || { compose ps; compose logs --tail=50 api; die "the API did not come up; see the logs above"; }

ip=$(hostname -I | awk '{print $1}')
cat <<DONE

Hub $HUB_NAME is up.
  API:       http://$ip:8000/health   (also http://$HUB_NAME.local:8000 on this network)
  Services:  hubctl status | hubctl logs | hubctl update | hubctl backup
  Secrets:   $POS_HOME/.env (root only)
  Data:      docker volume pos_pos-db
  Firewall:  SSH from $SSH_FROM; API, time (NTP) and mDNS from $LAN
Point the POS devices on this network at http://$ip:8000. Log out and in again for docker group membership.
DONE
