#!/usr/bin/env bash
set -Eeuo pipefail

base_dir=${PAST_EXAM_DEPLOY_DIR:-/home/opc/past-exam-managed}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

install -d -m 755 "$base_dir/bin" "$base_dir/config"
install -d -m 700 "$base_dir/state" "$base_dir/sources"
install -m 755 "$script_dir/deploy-main.sh" "$base_dir/bin/deploy-main.sh"
install -m 755 "$script_dir/switch-caddy.sh" "$base_dir/bin/switch-caddy.sh"
install -m 755 "$script_dir/rollback-main.sh" "$base_dir/bin/rollback-main.sh"
install -m 644 "$script_dir/docker-compose.managed.yml" "$base_dir/config/docker-compose.managed.yml"

sudo install -m 644 "$script_dir/past-exam-main-watch.service" /etc/systemd/system/past-exam-main-watch.service
sudo install -m 644 "$script_dir/past-exam-main-watch.timer" /etc/systemd/system/past-exam-main-watch.timer
sudo systemctl daemon-reload

printf 'Installed under %s. Run the first deployment manually before enabling the timer.\n' "$base_dir"
