#!/bin/bash
# Remove LanCache. Asks before deleting the cached games.
# Docker itself is left installed.
#
# Usage: sudo ./scripts/uninstall.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/lancache.conf"
[ "$EUID" -eq 0 ] || { echo "Please run as root: sudo ./scripts/uninstall.sh" >&2; exit 1; }

echo "Before continuing, change your router's DHCP DNS setting back to your"
echo "normal DNS server, or the gaming PCs will lose internet name resolution."
read -r -p "Remove LanCache now? [y/N]: " go
[[ "${go:-N}" =~ ^[Yy] ]] || { echo "Cancelled."; exit 0; }

CACHE_ROOT=""
[ -f "$DIR/.env" ] && CACHE_ROOT="$(grep -E '^CACHE_ROOT=' "$DIR/.env" | cut -d= -f2-)"

cd "$DIR"
if [ -f .env ]; then
  docker compose down --rmi all || true
fi

if [ -f "$RESOLVED_DROPIN" ]; then
  echo "==> Restoring systemd-resolved stub listener"
  rm -f "$RESOLVED_DROPIN"
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
fi

if [ -n "$CACHE_ROOT" ] && [ -d "$CACHE_ROOT" ]; then
  size="$(du -sh "$CACHE_ROOT" 2>/dev/null | cut -f1)"
  read -r -p "Also delete cached games in $CACHE_ROOT ($size)? [y/N]: " del
  if [[ "${del:-N}" =~ ^[Yy] ]]; then
    rm -rf --one-file-system "${CACHE_ROOT:?}/cache" "${CACHE_ROOT:?}/logs"
    rmdir "$CACHE_ROOT" 2>/dev/null || true
    echo "Cache deleted."
  else
    echo "Cache kept in $CACHE_ROOT."
  fi
fi

echo "LanCache removed."
