#!/bin/bash
# Update the LanCache containers. Restarting the DNS container also refreshes
# the list of cached game domains (uklans/cache-domains).
#
# Usage: sudo ./scripts/update.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$EUID" -eq 0 ] || { echo "Please run as root: sudo ./scripts/update.sh" >&2; exit 1; }
[ -f "$DIR/.env" ] || { echo "No .env found. Run install.sh first." >&2; exit 1; }

cd "$DIR"
echo "==> Pulling latest images"
docker compose pull
echo "==> Recreating containers"
docker compose up -d --force-recreate
echo "==> Removing old images"
docker image prune -f >/dev/null
echo "Done. Cached games are kept."
