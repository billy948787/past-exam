#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_SQL="${1:-}"
OUTPUT_SQL="${2:-}"

if [[ -z "${INPUT_SQL}" || -z "${OUTPUT_SQL}" || "${3:-}" != "" ]]; then
  printf 'Usage: %s input.sql output.sql\n' "$0" >&2
  exit 2
fi
if [[ ! -f "${INPUT_SQL}" ]]; then
  printf 'Input file does not exist: %s\n' "${INPUT_SQL}" >&2
  exit 2
fi
if [[ -e "${OUTPUT_SQL}" ]]; then
  printf 'Output file already exists: %s\n' "${OUTPUT_SQL}" >&2
  exit 2
fi
if [[ ! -d "$(dirname "${OUTPUT_SQL}")" ]]; then
  printf 'Output directory does not exist: %s\n' "$(dirname "${OUTPUT_SQL}")" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  printf 'Docker is required.\n' >&2
  exit 2
fi

RUN_ID="past-exam-migrate-$((10#$(date -u +%H%M%S)))-$$"
NETWORK_NAME="${RUN_ID}"
MYSQL_NAME="${RUN_ID}-mysql"
POSTGRES_NAME="${RUN_ID}-postgres"
MYSQL_VOLUME="${RUN_ID}-mysql-data"
POSTGRES_VOLUME="${RUN_ID}-postgres-data"
MIGRATOR_IMAGE="ntpu-past-exam-migrator:local"
MYSQL_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
POSTGRES_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
POSTGRES_DATABASE="past_exam"
POSTGRES_USER="past_exam"
DEFAULT_SOURCE_DATABASE="past_exam_source"
PARTIAL_OUTPUT="${OUTPUT_SQL}.partial.$$"

cleanup() {
  rm -f "${PARTIAL_OUTPUT}"
  docker rm -f "${MYSQL_NAME}" "${POSTGRES_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${MYSQL_VOLUME}" "${POSTGRES_VOLUME}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_mysql() {
  local attempt
  for attempt in $(seq 1 120); do
    if docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
      mysql --batch --skip-column-names -uroot -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Temporary MySQL did not become ready.\n' >&2
  return 1
}

wait_for_postgres() {
  local attempt
  for attempt in $(seq 1 120); do
    if docker exec "${POSTGRES_NAME}" \
      pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DATABASE}" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Temporary PostgreSQL did not become ready.\n' >&2
  return 1
}

printf 'Building migration tool...\n' >&2
docker build -t "${MIGRATOR_IMAGE}" "${ROOT_DIR}/ntpu-past-exam-service" >/dev/null

docker network create --internal "${NETWORK_NAME}" >/dev/null
docker volume create "${MYSQL_VOLUME}" >/dev/null
docker volume create "${POSTGRES_VOLUME}" >/dev/null

docker run -d \
  --name "${MYSQL_NAME}" \
  --network "${NETWORK_NAME}" \
  -e MYSQL_ROOT_PASSWORD="${MYSQL_PASSWORD}" \
  -e MYSQL_DATABASE="${DEFAULT_SOURCE_DATABASE}" \
  -v "${MYSQL_VOLUME}:/var/lib/mysql" \
  mysql:8.0 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_0900_ai_ci >/dev/null

docker run -d \
  --name "${POSTGRES_NAME}" \
  --network "${NETWORK_NAME}" \
  -e POSTGRES_DB="${POSTGRES_DATABASE}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  -v "${POSTGRES_VOLUME}:/var/lib/postgresql/data" \
  postgres:17-alpine >/dev/null

printf 'Waiting for temporary databases...\n' >&2
wait_for_mysql
wait_for_postgres

printf 'Importing MySQL dump...\n' >&2
docker exec -i -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
  mysql -uroot "${DEFAULT_SOURCE_DATABASE}" < "${INPUT_SQL}"

mapfile -t SOURCE_DATABASES < <(
  docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
    mysql -N -uroot -e \
    "SELECT table_schema FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','mysql','performance_schema','sys') GROUP BY table_schema HAVING COUNT(*) > 0 ORDER BY table_schema"
)
if [[ "${#SOURCE_DATABASES[@]}" -ne 1 ]]; then
  printf 'Expected exactly one non-empty source database, found %s.\n' \
    "${#SOURCE_DATABASES[@]}" >&2
  exit 2
fi
SOURCE_DATABASE="${SOURCE_DATABASES[0]}"

SKIPPED_ORPHAN_POST_FILES="$(
  docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
    mysql --batch --skip-column-names -uroot "${SOURCE_DATABASE}" -e "
      SELECT COUNT(*)
      FROM posts_files AS orphan
      LEFT JOIN posts AS parent ON parent.id = orphan.post_id
      WHERE orphan.post_id IS NOT NULL AND parent.id IS NULL;
    "
)"
if [[ "${SKIPPED_ORPHAN_POST_FILES}" -gt 0 ]]; then
  docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
    mysql -uroot "${SOURCE_DATABASE}" -e "
      DELETE orphan
      FROM posts_files AS orphan
      LEFT JOIN posts AS parent ON parent.id = orphan.post_id
      WHERE orphan.post_id IS NOT NULL AND parent.id IS NULL;
    "
fi

MIGRATOR_ENV=(
  -e PYTHONPATH=/
  -e DATABASE_DRIVER=postgresql+psycopg
  -e DATABASE_HOST="${POSTGRES_NAME}"
  -e DATABASE_PORT=5432
  -e DATABASE_USERNAME="${POSTGRES_USER}"
  -e DATABASE_PASSWORD="${POSTGRES_PASSWORD}"
  -e DATABASE="${POSTGRES_DATABASE}"
  -e MIGRATION_SOURCE_HOST="${MYSQL_NAME}"
  -e MIGRATION_SOURCE_PORT=3306
  -e MIGRATION_SOURCE_USERNAME=root
  -e MIGRATION_SOURCE_PASSWORD="${MYSQL_PASSWORD}"
  -e MIGRATION_SOURCE_DATABASE="${SOURCE_DATABASE}"
  -e MIGRATION_SOURCE_TIMEZONE=Asia/Taipei
)

printf 'Checking source data...\n' >&2
docker run --rm --network "${NETWORK_NAME}" "${MIGRATOR_ENV[@]}" \
  -v "${ROOT_DIR}/deploy/migrate_mysql_to_postgres.py:/migrate_mysql_to_postgres.py:ro" \
  "${MIGRATOR_IMAGE}" python /migrate_mysql_to_postgres.py preflight

printf 'Migrating and verifying...\n' >&2
docker run --rm --network "${NETWORK_NAME}" "${MIGRATOR_ENV[@]}" \
  -v "${ROOT_DIR}/deploy/migrate_mysql_to_postgres.py:/migrate_mysql_to_postgres.py:ro" \
  "${MIGRATOR_IMAGE}" python /migrate_mysql_to_postgres.py migrate

printf 'Writing PostgreSQL dump...\n' >&2
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_NAME}" \
  pg_dump \
  --username="${POSTGRES_USER}" \
  --dbname="${POSTGRES_DATABASE}" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges > "${PARTIAL_OUTPUT}"
mv "${PARTIAL_OUTPUT}" "${OUTPUT_SQL}"

printf 'Created PostgreSQL dump: %s\n' "${OUTPUT_SQL}" >&2
if [[ "${SKIPPED_ORPHAN_POST_FILES}" -gt 0 ]]; then
  printf 'WARNING: skipped %s posts_files rows whose parent posts do not exist. The input SQL and R2 objects were not modified.\n' \
    "${SKIPPED_ORPHAN_POST_FILES}" >&2
fi
