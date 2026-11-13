#!/bin/bash
# LanCache installer for Ubuntu
# Caches game downloads (Steam, Epic, Battle.net, Riot and more) on a local
# server, so every PC in a gaming center downloads each update only once.
#
# Usage: sudo ./install.sh [options]
#   -y, --yes            Accept detected defaults without asking
#   --ip IP              LAN IP of this server
#   --cache-dir PATH     Where to store cached games (default /srv/lancache)
#   --size SIZE          Max cache size, e.g. 1500g (default: 90% of free space)
#   --dns "A; B"         Upstream DNS servers (default "1.1.1.1; 1.0.0.1")
#   -h, --help           Show this help

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/lancache.conf"

ASSUME_YES=0
LAN_IP=""
CACHE_ROOT="/srv/lancache"
CACHE_SIZE=""
UPSTREAM_DNS="1.1.1.1; 1.0.0.1"
MIN_FREE_GB=20

c_green=$'\e[32m'; c_red=$'\e[31m'; c_yellow=$'\e[33m'; c_bold=$'\e[1m'; c_off=$'\e[0m'
info()  { echo "${c_bold}==>${c_off} $*"; }
ok()    { echo "${c_green}OK${c_off}  $*"; }
warn()  { echo "${c_yellow}WARN${c_off} $*"; }
die()   { echo "${c_red}ERROR${c_off} $*" >&2; exit 1; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --ip) LAN_IP="${2:?--ip needs a value}"; shift ;;
    --cache-dir) CACHE_ROOT="${2:?--cache-dir needs a value}"; shift ;;
    --size) CACHE_SIZE="${2:?--size needs a value}"; shift ;;
    --dns) UPSTREAM_DNS="${2:?--dns needs a value}"; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

ask() { # ask "Question" default -> echoes answer
  local q="$1" def="$2" ans
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then echo "$def"; return; fi
  read -r -p "$q [$def]: " ans
  echo "${ans:-$def}"
}

# ---------------------------------------------------------------- checks
[ "$EUID" -eq 0 ] || die "Please run as root: sudo ./install.sh"
[ -f /etc/os-release ] && . /etc/os-release
[ "${ID:-}" = "ubuntu" ] || warn "This script is written for Ubuntu; detected '${ID:-unknown}'. Continuing anyway."
command -v ip >/dev/null || die "'ip' command not found (install iproute2)."

info "LanCache installer for Ubuntu"

# ---------------------------------------------------------------- settings
if [ -z "$LAN_IP" ]; then
  detected_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [ -n "$detected_ip" ] || detected_ip="$(hostname -I | awk '{print $1}')"
  LAN_IP="$(ask "LAN IP of this server" "$detected_ip")"
fi
[[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "'$LAN_IP' is not a valid IPv4 address."
ip -4 addr show | grep -q "inet $LAN_IP/" || die "$LAN_IP is not assigned to this server. Give the server a static IP first."
# lancache-dns only accepts private LAN addresses (RFC 1918)
[[ "$LAN_IP" =~ ^10\. || "$LAN_IP" =~ ^192\.168\. || "$LAN_IP" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] \
  || die "$LAN_IP is not a private LAN address. LanCache must run on a LAN IP like 192.168.x.x, 10.x.x.x or 172.16-31.x.x."
# the cache container listens on IPv6 as well and will not start if the kernel has IPv6 removed
[ -e /proc/net/if_inet6 ] \
  || die "IPv6 is disabled in the kernel (ipv6.disable=1). LanCache needs it available: remove ipv6.disable=1 from GRUB_CMDLINE_LINUX in /etc/default/grub, run sudo update-grub and reboot. You do not need an IPv6 network."

CACHE_ROOT="$(ask "Folder for cached games" "$CACHE_ROOT")"
mkdir -p "$CACHE_ROOT/cache" "$CACHE_ROOT/logs"

free_gb="$(df -BG --output=avail "$CACHE_ROOT" | tail -1 | tr -dc '0-9')"
if [ -z "$CACHE_SIZE" ]; then
  suggested=$(( (free_gb - MIN_FREE_GB) * 9 / 10 ))
  [ "$suggested" -ge 10 ] || die "Only ${free_gb}g free in $CACHE_ROOT. Use a bigger disk (--cache-dir)."
  CACHE_SIZE="$(ask "Maximum cache size ($free_gb GB free on that disk)" "${suggested}g")"
fi
[[ "$CACHE_SIZE" =~ ^[0-9]+[gGtT]$ ]] || die "Cache size must look like 500g or 2t."
size_num="${CACHE_SIZE%[gGtT]}"
case "$CACHE_SIZE" in *[tT]) size_gb=$(( size_num * 1000 )) ;; *) size_gb=$size_num ;; esac
CACHE_SIZE="${size_gb}g"
[ "$size_gb" -le "$free_gb" ] || warn "Cache size ${size_gb}g is larger than the free space (${free_gb}g). LanCache will keep MIN_FREE_DISK free, but consider a bigger disk."
[ "$free_gb" -ge 200 ] || warn "Only ${free_gb}g free. A gaming center usually needs 1 TB or more to cache popular games."

# 250m of index memory per 1000g of cache, rounded up
index_mb=$(( (size_gb + 999) / 1000 * 250 ))
[ "$index_mb" -lt 250 ] && index_mb=250

UPSTREAM_DNS="$(ask "Upstream DNS servers (separate with ;)" "$UPSTREAM_DNS")"
TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
TZ_NAME="${TZ_NAME:-Etc/UTC}"

echo
echo "  Server IP     $LAN_IP"
echo "  Cache folder  $CACHE_ROOT"
echo "  Cache size    $CACHE_SIZE (index ${index_mb}m)"
echo "  Upstream DNS  $UPSTREAM_DNS"
echo "  Timezone      $TZ_NAME"
echo
if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
  read -r -p "Install with these settings? [Y/n]: " go
  [[ "${go:-Y}" =~ ^[Yy] ]] || die "Cancelled."
fi

# ---------------------------------------------------------------- ports
port_users() { ss -Hlnptu "( sport = :$1 )" 2>/dev/null | grep -v docker-proxy || true; }

for p in 80 443; do
  if [ -n "$(port_users "$p")" ]; then
    echo "$(port_users "$p")"
    die "Port $p is already in use (often Apache or Nginx). LanCache needs ports 80 and 443 on this server. Stop that service first, e.g.: sudo systemctl disable --now apache2"
  fi
done

dns_users="$(ss -Hlnptu "( sport = :53 )" 2>/dev/null | grep -v docker-proxy | grep -E "(\*|0\.0\.0\.0|\[::\]|${LAN_IP//./\\.}):53 " || true)"
if [ -n "$dns_users" ]; then
  if echo "$dns_users" | grep -q systemd-resolve; then
    info "Freeing port 53 from the systemd-resolved stub listener"
    mkdir -p "$(dirname "$RESOLVED_DROPIN")"
    printf '[Resolve]\nDNSStubListener=no\n' > "$RESOLVED_DROPIN"
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    ok "systemd-resolved no longer listens on port 53"
  else
    echo "$dns_users"
    die "Port 53 on $LAN_IP is used by another DNS server (shown above). Stop it before installing LanCache."
  fi
fi

# ---------------------------------------------------------------- docker
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  info "Installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  if ! apt-get install -y docker.io docker-compose-v2; then
    warn "Ubuntu packages not available, using Docker's official install script"
    apt-get install -y curl
    curl -fsSL https://get.docker.com | sh
  fi
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Check: sudo systemctl status docker"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not available after install."
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) ready"

# ---------------------------------------------------------------- config
if [ -f "$ENV_FILE" ]; then
  cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
  warn "Existing .env backed up"
fi
cat > "$ENV_FILE" <<EOF
## Created by install.sh on $(date '+%Y-%m-%d %H:%M'). See .env.example for notes.
USE_GENERIC_CACHE=true
LANCACHE_IP=$LAN_IP
DNS_BIND_IP=$LAN_IP
UPSTREAM_DNS=$UPSTREAM_DNS
CACHE_ROOT=$CACHE_ROOT
CACHE_DISK_SIZE=$CACHE_SIZE
MIN_FREE_DISK=${MIN_FREE_GB}g
CACHE_INDEX_SIZE=${index_mb}m
CACHE_MAX_AGE=3650d
TZ=$TZ_NAME
EOF
ok "Settings written to $ENV_FILE"

# ---------------------------------------------------------------- firewall
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  info "Opening firewall ports 53, 80, 443"
  ufw allow 53/udp >/dev/null
  ufw allow 53/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ok "Firewall updated"
fi

# ---------------------------------------------------------------- start
info "Downloading and starting LanCache containers"
cd "$DIR"
docker compose pull
docker compose up -d
ok "Containers started"

# ---------------------------------------------------------------- verify
info "Checking DNS (the DNS container needs a moment to load the domain lists)"
command -v dig >/dev/null || apt-get install -y dnsutils >/dev/null 2>&1 || true
# 1) inside the container: is the cache-domains config loaded?
inside=0
for _ in $(seq 1 30); do
  answer="$(docker exec lancache-dns dig +short +time=2 +tries=1 @127.0.0.1 lancache.steamcontent.com 2>/dev/null | tail -1 || true)"
  if [ "$answer" = "$LAN_IP" ]; then inside=1; break; fi
  sleep 4
done
# 2) on the LAN IP: can clients reach it?
outside=0
if [ "$inside" -eq 1 ]; then
  answer="$(dig +short +time=3 +tries=2 @"$LAN_IP" lancache.steamcontent.com 2>/dev/null | tail -1 || true)"
  [ "$answer" = "$LAN_IP" ] && outside=1
fi
if [ "$outside" -eq 1 ]; then
  ok "DNS works: lancache.steamcontent.com resolves to $LAN_IP"
elif [ "$inside" -eq 1 ]; then
  warn "The DNS container is configured correctly, but $LAN_IP:53 did not answer from this server. Check the firewall and: sudo ss -lunp | grep :53"
else
  warn "The DNS container is not ready yet. Check the logs with: sudo docker logs lancache-dns"
fi
if ! docker ps --filter name='^lancache$' --filter status=running --format '{{.Names}}' | grep -q .; then
  warn "The cache container is not running. Check the logs with: sudo docker logs lancache"
fi

cat <<EOF

${c_green}${c_bold}LanCache is running.${c_off}

Next step: make the gaming PCs use this server for DNS.
  In your router's DHCP settings, set the DNS server to:  ${c_bold}$LAN_IP${c_off}
  Then restart the PCs (or run "ipconfig /renew" on each).

Useful commands (run from $DIR):
  sudo ./scripts/status.sh      cache usage, hit rate, data saved
  sudo ./scripts/update.sh      update the containers and domain lists
  sudo ./scripts/uninstall.sh   remove LanCache
EOF
