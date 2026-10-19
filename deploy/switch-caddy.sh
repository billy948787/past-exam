#!/usr/bin/env bash
set -Eeuo pipefail

slot=${1:-}
case "$slot" in
  blue|green) ;;
  *)
    printf 'Usage: %s blue|green\n' "$0" >&2
    exit 2
    ;;
esac

caddy_file=${CADDY_FILE:-/home/opc/vaultwarden/Caddyfile}
state_dir=${PAST_EXAM_STATE_DIR:-/home/opc/past-exam-managed/state}
frontend_upstream="past-exam-frontend-${slot}"
backend_upstream="past-exam-api-${slot}"

install -d -m 700 "$state_dir/caddy-backups"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="$state_dir/caddy-backups/Caddyfile.${timestamp}"
temporary=$(mktemp "$state_dir/Caddyfile.XXXXXX")
trap 'rm -f "$temporary"' EXIT

cp -a "$caddy_file" "$backup"
sed -E \
  -e "s#reverse_proxy past-exam-frontend(-(coolify|blue|green))?:8080#reverse_proxy ${frontend_upstream}:8080#" \
  -e "s#reverse_proxy past-exam-api(-(blue|green))?:8080#reverse_proxy ${backend_upstream}:8080#" \
  "$caddy_file" > "$temporary"

grep -Fq "reverse_proxy ${frontend_upstream}:8080" "$temporary"
grep -Fq "reverse_proxy ${backend_upstream}:8080" "$temporary"

# Copy in place so Docker's bind-mounted Caddyfile keeps the same inode.
cp "$temporary" "$caddy_file"
if ! docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
  cp "$backup" "$caddy_file"
  printf 'Caddy validation failed; restored %s\n' "$backup" >&2
  exit 1
fi

if ! docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
  cp "$backup" "$caddy_file"
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || true
  printf 'Caddy reload failed; restored %s\n' "$backup" >&2
  exit 1
fi

printf '%s\n' "$backup"
