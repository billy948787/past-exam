#!/usr/bin/env bash
set -Eeuo pipefail

slot=${1:-}
caddy_file=${CADDY_FILE:-/home/opc/vaultwarden/Caddyfile}
state_dir=${PAST_EXAM_STATE_DIR:-/home/opc/past-exam-managed/state}
container_candidate=/tmp/Caddyfile.past-exam-managed

stage_and_validate() {
  local source_file=$1
  docker cp "$source_file" "caddy:$container_candidate"
  docker exec caddy caddy validate --config "$container_candidate" --adapter caddyfile >/dev/null
}

reload_staged() {
  docker exec caddy caddy reload --config "$container_candidate" --adapter caddyfile >/dev/null
}

if [[ "$slot" == --restore ]]; then
  restore_file=${2:-}
  test -r "$restore_file"
  cp "$restore_file" "$caddy_file"
  stage_and_validate "$restore_file"
  reload_staged
  exit 0
fi

case "$slot" in
  blue|green) ;;
  *)
    printf 'Usage: %s blue|green\n' "$0" >&2
    exit 2
    ;;
esac

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

# Persist the next configuration for container restarts. Load the same candidate
# through /tmp because a single-file bind mount can keep an older host inode.
cp "$temporary" "$caddy_file"
if ! stage_and_validate "$temporary"; then
  cp "$backup" "$caddy_file"
  stage_and_validate "$backup" && reload_staged || true
  printf 'Caddy validation failed; restored %s\n' "$backup" >&2
  exit 1
fi

if ! reload_staged; then
  cp "$backup" "$caddy_file"
  stage_and_validate "$backup" && reload_staged || true
  printf 'Caddy reload failed; restored %s\n' "$backup" >&2
  exit 1
fi

printf '%s\n' "$backup"
