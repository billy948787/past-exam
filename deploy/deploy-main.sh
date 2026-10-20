#!/usr/bin/env bash
set -Eeuo pipefail

base_dir=${PAST_EXAM_DEPLOY_DIR:-/home/opc/past-exam-managed}
source_dir="$base_dir/sources"
state_dir="$base_dir/state"
config_dir="$base_dir/config"
env_file=${PAST_EXAM_ENV_FILE:-/home/opc/past-exam/oracle.env}
compose_file="$config_dir/docker-compose.managed.yml"
switch_caddy=${PAST_EXAM_SWITCH_CADDY:-/usr/local/bin/past-exam-switch-caddy}
frontend_dir="$source_dir/frontend"
backend_dir="$source_dir/backend"

frontend_repo=https://github.com/billy948787/ntpu-past-exam.git
backend_repo=https://github.com/billy948787/ntpu-past-exam-service.git

install -d -m 700 "$state_dir" "$source_dir"
exec 9>"$state_dir/deploy.lock"
if ! flock -n 9; then
  printf 'Another deployment is already running.\n'
  exit 0
fi

for command_name in curl docker flock git; do
  command -v "$command_name" >/dev/null
done
test -r "$env_file"
test -r "$compose_file"
test -x "$switch_caddy"
docker network inspect past-exam-internal past-exam-caddy >/dev/null

update_repo() {
  local url=$1
  local directory=$2

  if [[ ! -d "$directory/.git" ]]; then
    if [[ -e "$directory" ]]; then
      printf 'Refusing to clone over non-Git path %s\n' "$directory" >&2
      return 1
    fi
    git clone --branch main --single-branch "$url" "$directory"
  else
    if ! git -C "$directory" diff --quiet || ! git -C "$directory" diff --cached --quiet; then
      printf 'Refusing to overwrite local changes in %s\n' "$directory" >&2
      return 1
    fi
    git -C "$directory" fetch --prune origin main
    git -C "$directory" switch main
    git -C "$directory" merge --ff-only origin/main
  fi
}

update_repo "$frontend_repo" "$frontend_dir"
update_repo "$backend_repo" "$backend_dir"

frontend_sha=$(git -C "$frontend_dir" rev-parse HEAD)
backend_sha=$(git -C "$backend_dir" rev-parse HEAD)
current_state="$state_dir/current.env"

read_state_value() {
  local file=$1
  local key=$2
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

current_slot=
current_frontend_sha=
current_backend_sha=
if [[ -r "$current_state" ]]; then
  current_slot=$(read_state_value "$current_state" SLOT)
  current_frontend_sha=$(read_state_value "$current_state" FRONTEND_SHA)
  current_backend_sha=$(read_state_value "$current_state" BACKEND_SHA)
fi

if [[ ${FORCE_DEPLOY:-0} != 1 \
  && "$frontend_sha" == "$current_frontend_sha" \
  && "$backend_sha" == "$current_backend_sha" ]]; then
  printf 'main is unchanged: frontend=%s backend=%s\n' "${frontend_sha:0:12}" "${backend_sha:0:12}"
  exit 0
fi

failed_state="$state_dir/failed.env"
if [[ ${FORCE_DEPLOY:-0} != 1 && -r "$failed_state" ]]; then
  failed_frontend_sha=$(read_state_value "$failed_state" FRONTEND_SHA)
  failed_backend_sha=$(read_state_value "$failed_state" BACKEND_SHA)
  failed_at_epoch=$(read_state_value "$failed_state" FAILED_AT_EPOCH)
  now_epoch=$(date +%s)
  if [[ "$frontend_sha" == "$failed_frontend_sha" \
    && "$backend_sha" == "$failed_backend_sha" \
    && "$failed_at_epoch" =~ ^[0-9]+$ \
    && $((now_epoch - failed_at_epoch)) -lt 900 ]]; then
    printf 'Skipping recently failed main for 15 minutes: frontend=%s backend=%s\n' \
      "${frontend_sha:0:12}" "${backend_sha:0:12}"
    exit 0
  fi
fi

mark_failed() {
  local exit_status=$?
  trap - ERR
  local failed_temporary
  failed_temporary=$(mktemp "$state_dir/failed.env.XXXXXX")
  {
    printf 'FRONTEND_SHA=%s\n' "$frontend_sha"
    printf 'BACKEND_SHA=%s\n' "$backend_sha"
    printf 'FAILED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'FAILED_AT_EPOCH=%s\n' "$(date +%s)"
  } > "$failed_temporary"
  chmod 600 "$failed_temporary"
  mv "$failed_temporary" "$failed_state"
  exit "$exit_status"
}
trap mark_failed ERR

case "$current_slot" in
  blue) deploy_slot=green ;;
  green) deploy_slot=blue ;;
  *) deploy_slot=blue ;;
esac

export DEPLOY_SLOT="$deploy_slot"
export FRONTEND_SOURCE_DIR="$frontend_dir"
export BACKEND_SOURCE_DIR="$backend_dir"
export FRONTEND_SHA="$frontend_sha"
export BACKEND_SHA="$backend_sha"
export FRONTEND_IMAGE="ntpu-past-exam-frontend:${frontend_sha:0:12}"
export BACKEND_IMAGE="ntpu-past-exam-backend:${backend_sha:0:12}"

project="past-exam-${deploy_slot}"
compose=(docker compose --env-file "$env_file" -p "$project" -f "$compose_file")

printf 'Building main: slot=%s frontend=%s backend=%s\n' \
  "$deploy_slot" "${frontend_sha:0:12}" "${backend_sha:0:12}"
"${compose[@]}" config --quiet
"${compose[@]}" build
"${compose[@]}" up -d --no-build --remove-orphans

wait_for_health() {
  local service=$1
  local container_id
  local status
  container_id=$("${compose[@]}" ps -q "$service")
  test -n "$container_id"

  for _ in $(seq 1 60); do
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")
    case "$status" in
      healthy|running)
        printf '%s is %s\n' "$service" "$status"
        return 0
        ;;
      unhealthy|exited|dead)
        printf '%s became %s\n' "$service" "$status" >&2
        docker logs --tail 80 "$container_id" >&2 || true
        return 1
        ;;
    esac
    sleep 2
  done

  printf 'Timed out waiting for %s\n' "$service" >&2
  docker logs --tail 80 "$container_id" >&2 || true
  return 1
}

wait_for_health backend
wait_for_health frontend

backend_id=$("${compose[@]}" ps -q backend)
frontend_id=$("${compose[@]}" ps -q frontend)
docker exec "$backend_id" python -c \
  "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/ping', timeout=5)"
docker exec "$frontend_id" wget -q -O /dev/null http://127.0.0.1:8080/healthz

backup_timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="/home/opc/backups/past-exam-auto/$backup_timestamp"
install -d -m 700 "$backup_dir"
docker exec ntpu-past-exam-postgres-1 /bin/sh -c \
  'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "$backup_dir/postgres.dump"
docker exec -i ntpu-past-exam-postgres-1 pg_restore -l \
  < "$backup_dir/postgres.dump" > /dev/null
chmod 600 "$backup_dir/postgres.dump"

caddy_backup=$("$switch_caddy" "$deploy_slot")

public_health_ok=0
for _ in $(seq 1 10); do
  if curl --fail --silent --show-error --max-time 15 \
      -o /dev/null https://past-exam.ntpu.cc/healthz \
    && curl --fail --silent --show-error --max-time 15 \
      -o /dev/null https://past-exam-api.ntpu.cc/ping; then
    public_health_ok=1
    break
  fi
  sleep 2
done

if [[ "$public_health_ok" != 1 ]]; then
  cp "$caddy_backup" /home/opc/vaultwarden/Caddyfile
  docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  printf 'Public health check failed; restored Caddy configuration.\n' >&2
  exit 1
fi

if [[ -r "$current_state" ]]; then
  cp "$current_state" "$state_dir/previous.env"
fi

new_state=$(mktemp "$state_dir/current.env.XXXXXX")
{
  printf 'SLOT=%s\n' "$deploy_slot"
  printf 'FRONTEND_SHA=%s\n' "$frontend_sha"
  printf 'BACKEND_SHA=%s\n' "$backend_sha"
  printf 'DEPLOYED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'CADDY_BACKUP=%s\n' "$caddy_backup"
} > "$new_state"
chmod 600 "$new_state"
mv "$new_state" "$current_state"
rm -f "$failed_state"
trap - ERR

printf 'Deployment complete: slot=%s frontend=%s backend=%s\n' \
  "$deploy_slot" "${frontend_sha:0:12}" "${backend_sha:0:12}"
