#!/usr/bin/env bash
set -euo pipefail
umask 077

INPUT_SQL="${1:-}"
if [[ -z "${INPUT_SQL}" || "${2:-}" != "" ]]; then
  printf 'Usage: %s input.sql\n' "$0" >&2
  exit 2
fi
if [[ ! -f "${INPUT_SQL}" ]]; then
  printf 'Input file does not exist: %s\n' "${INPUT_SQL}" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  printf 'Docker is required.\n' >&2
  exit 2
fi

RUN_ID="past-exam-inspect-$((10#$(date -u +%H%M%S)))-$$"
MYSQL_NAME="${RUN_ID}-mysql"
MYSQL_VOLUME="${RUN_ID}-mysql-data"
MYSQL_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
DEFAULT_SOURCE_DATABASE="past_exam_source"

cleanup() {
  docker rm -f "${MYSQL_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${MYSQL_VOLUME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker volume create "${MYSQL_VOLUME}" >/dev/null
docker run -d \
  --name "${MYSQL_NAME}" \
  -e MYSQL_ROOT_PASSWORD="${MYSQL_PASSWORD}" \
  -e MYSQL_DATABASE="${DEFAULT_SOURCE_DATABASE}" \
  -v "${MYSQL_VOLUME}:/var/lib/mysql" \
  mysql:8.0 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_0900_ai_ci >/dev/null

printf 'Waiting for temporary MySQL...\n' >&2
ready=false
for attempt in $(seq 1 120); do
  if docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
    mysql --batch --skip-column-names -uroot -e 'SELECT 1' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "${ready}" != "true" ]]; then
  printf 'Temporary MySQL did not become ready.\n' >&2
  exit 1
fi

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

printf '\nOrphan posts_files rows (one JSON object per row):\n'
docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
  mysql --batch --raw --skip-column-names -uroot "${SOURCE_DATABASE}" -e "
    SELECT JSON_OBJECT(
      'file_id', orphan.id,
      'missing_post_id', orphan.post_id,
      'url', orphan.url,
      'create_time', orphan.create_time,
      'updated_time', orphan.updated_time,
      'valid_posts_with_same_url', COALESCE(
        (
          SELECT JSON_ARRAYAGG(valid.post_id)
          FROM posts_files AS valid
          INNER JOIN posts AS valid_post ON valid_post.id = valid.post_id
          WHERE valid.url = orphan.url AND valid.id <> orphan.id
        ),
        JSON_ARRAY()
      )
    )
    FROM posts_files AS orphan
    LEFT JOIN posts AS parent ON parent.id = orphan.post_id
    WHERE orphan.post_id IS NOT NULL AND parent.id IS NULL
    ORDER BY orphan.post_id, orphan.id;
  "

printf '\nSummary by missing post_id:\n'
docker exec -e MYSQL_PWD="${MYSQL_PASSWORD}" "${MYSQL_NAME}" \
  mysql --table -uroot "${SOURCE_DATABASE}" -e "
    SELECT orphan.post_id AS missing_post_id,
           COUNT(*) AS orphan_file_count,
           MIN(orphan.create_time) AS first_file_time,
           MAX(orphan.create_time) AS last_file_time
    FROM posts_files AS orphan
    LEFT JOIN posts AS parent ON parent.id = orphan.post_id
    WHERE orphan.post_id IS NOT NULL AND parent.id IS NULL
    GROUP BY orphan.post_id
    ORDER BY orphan.post_id;
  "

printf '\nThe input dump was not modified. Temporary MySQL data is now being deleted.\n' >&2
