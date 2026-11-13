#!/bin/bash
# Show LanCache status: containers, disk usage and how much download traffic
# was served from the cache instead of the internet.
#
# Usage: sudo ./scripts/status.sh [days]   (default: today only, 0 = all logs)

set -euo pipefail
export LC_ALL=C  # log dates use English month names

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$DIR/.env" ] || { echo "No .env found. Run install.sh first." >&2; exit 1; }
[[ "${1:-1}" =~ ^[0-9]+$ ]] || { echo "Usage: sudo ./scripts/status.sh [days]   (0 = all logs)" >&2; exit 1; }
CACHE_ROOT="$(grep -E '^CACHE_ROOT=' "$DIR/.env" | cut -d= -f2-)"
CACHE_LIMIT="$(grep -E '^CACHE_DISK_SIZE=' "$DIR/.env" | cut -d= -f2-)"
LOG="$CACHE_ROOT/logs/access.log"
DAYS="${1:-1}"

echo "== Containers"
docker ps -a --filter name=lancache --format '  {{.Names}}\t{{.Status}}' || true

echo
echo "== Cache disk"
used="$(du -sh "$CACHE_ROOT/cache" 2>/dev/null | cut -f1 || echo '?')"
echo "  Used: $used of $CACHE_LIMIT limit"
df -h --output=source,size,used,avail,pcent "$CACHE_ROOT" | sed 's/^/  /'

echo
if [ ! -s "$LOG" ]; then
  echo "== Traffic: no downloads logged yet."
  exit 0
fi

if [ "$DAYS" -eq 0 ]; then
  echo "== Traffic (all logs)"
  filter='[0-9]{2}/[A-Za-z]{3}/[0-9]{4}'
else
  echo "== Traffic (last $DAYS day(s))"
  # Log dates look like [13/Nov/2026:14:02:11 +0100]
  filter="$(for i in $(seq 0 $((DAYS - 1))); do date -d "-$i day" '+%d/%b/%Y'; done | paste -sd'|')"
fi

grep -E "\[($filter):" "$LOG" 2>/dev/null | awk -F'"' '
  {
    split($1, a, " "); svc = a[1]; gsub(/[\[\]]/, "", svc)
    split($3, b, " "); bytes = b[2] + 0
    st = $8
    if (st == "HIT")  { hit[svc] += bytes; th += bytes }
    else              { miss[svc] += bytes; tm += bytes }
    seen[svc] = 1
  }
  function gb(x) { return sprintf("%.2f GB", x / 1e9) }
  END {
    if (th + tm == 0) { print "  No downloads in this period."; exit }
    printf "  %-14s %14s %14s %8s\n", "Service", "From cache", "From internet", "Hit rate"
    for (s in seen) {
      t = hit[s] + miss[s]
      printf "  %-14s %14s %14s %7.0f%%\n", s, gb(hit[s]), gb(miss[s]), (t ? hit[s] * 100 / t : 0)
    }
    printf "  %-14s %14s %14s %7.0f%%\n", "TOTAL", gb(th), gb(tm), th * 100 / (th + tm)
    print ""
    print "  Internet bandwidth saved: " gb(th)
  }'
