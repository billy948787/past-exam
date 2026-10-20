#!/usr/bin/env bash
set -Eeuo pipefail

base_dir=${PAST_EXAM_DEPLOY_DIR:-/home/opc/past-exam-managed}
state_dir="$base_dir/state"
previous_state="$state_dir/previous.env"
current_state="$state_dir/current.env"
switch_caddy=${PAST_EXAM_SWITCH_CADDY:-/usr/local/bin/past-exam-switch-caddy}

test -r "$previous_state"
test -r "$current_state"
exec 9>"$state_dir/deploy.lock"
flock -n 9

read_state_value() {
  local file=$1
  local key=$2
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

previous_slot=$(read_state_value "$previous_state" SLOT)
case "$previous_slot" in
  blue|green) ;;
  *)
    printf 'Invalid previous slot: %s\n' "$previous_slot" >&2
    exit 1
    ;;
esac

for service in backend frontend; do
  container_id=$(docker ps -q \
    --filter "label=com.docker.compose.project=past-exam-${previous_slot}" \
    --filter "label=com.docker.compose.service=${service}")
  test -n "$container_id"
  test "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" = healthy
done

"$switch_caddy" "$previous_slot" >/dev/null
curl --fail --silent --show-error --max-time 15 -o /dev/null https://past-exam.ntpu.cc/healthz
curl --fail --silent --show-error --max-time 15 -o /dev/null https://past-exam-api.ntpu.cc/ping

temporary=$(mktemp "$state_dir/rollback.XXXXXX")
cp "$current_state" "$temporary"
cp "$previous_state" "$current_state"
cp "$temporary" "$previous_state"
rm -f "$temporary"
printf 'Rolled back to %s.\n' "$previous_slot"
