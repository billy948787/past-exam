# Oracle Deployment

The production hostnames are `past-exam.ntpu.cc` and
`past-exam-api.ntpu.cc`. Existing Cloudflare R2 storage remains external.
PostgreSQL and Redis are private and have no host port bindings.

Do not run the development `docker-compose.yml` or `bootstrap.sh` on Oracle.

## Blocking Prerequisites

- Rotate the Cloudflare API token that was exposed during inspection. Install
  and verify the replacement before revoking the old token so existing
  certificate renewal is not interrupted.
- Build a PostgreSQL baseline and complete the private MySQL data migration.
  The historical Alembic chain contains MySQL-only SQL and must not be replayed
  against PostgreSQL.
- Preserve the existing `HASH_KEY` if existing JWTs should remain valid.
- Register `https://past-exam.ntpu.cc/login` with Google OAuth.
- Configure R2 CORS for `https://past-exam.ntpu.cc` and preserve the existing
  bucket, object keys, endpoint, credentials, and public `R2_FILE_PATH` URL.

## Environment

```bash
cp oracle.env.example oracle.env
chmod 600 oracle.env
```

Fill every required value in `oracle.env`. It must never be committed or sent.
Frontend values are embedded at image build time, so rebuild the frontend after
changing any `NEXT_PUBLIC_*` value.

Validate the resulting Compose model without printing it, because expanded
output contains secrets:

```bash
docker compose --env-file oracle.env -f docker-compose.oracle.yml config --quiet
```

## Caddy Network

Create a network dedicated to Caddy and this application:

```bash
docker network create past-exam-caddy
```

In `/home/opc/vaultwarden/docker-compose.yml`, keep Caddy on its existing
`default` network and add the external network:

```yaml
services:
  caddy:
    networks:
      - default
      - past-exam-caddy

networks:
  past-exam-caddy:
    external: true
```

Back up the existing files before recreating Caddy:

```bash
cp /home/opc/vaultwarden/Caddyfile /home/opc/vaultwarden/Caddyfile.before-past-exam
cp /home/opc/vaultwarden/docker-compose.yml /home/opc/vaultwarden/docker-compose.yml.before-past-exam
```

Recreate only Caddy from the existing project, then verify Vaultwarden before
continuing:

```bash
docker compose -f /home/opc/vaultwarden/docker-compose.yml up -d caddy
docker inspect caddy --format '{{json .NetworkSettings.Networks}}'
curl --fail --silent --show-error https://vault.maclinux.win/alive
```

## Build And Database Migration

Build with final frontend values:

```bash
docker compose --env-file oracle.env -f docker-compose.oracle.yml build
```

Start only PostgreSQL and Redis while migrating data:

```bash
docker compose --env-file oracle.env -f docker-compose.oracle.yml up -d postgres redis
```

Do not start the backend until the PostgreSQL baseline, data import, integrity
checks, row-count checks, and Alembic stamp are complete. Follow
`deploy/README.migration.md` for the single-file SQL dump workflow.

## Pre-Cutover Test

Start the application without changing Caddy routing:

```bash
docker compose --env-file oracle.env -f docker-compose.oracle.yml up -d backend frontend
docker compose --env-file oracle.env -f docker-compose.oracle.yml ps
```

Test both upstreams from their private network:

```bash
docker run --rm --network past-exam-caddy curlimages/curl:8.12.1 --fail http://past-exam-frontend:8080/healthz
docker run --rm --network past-exam-caddy curlimages/curl:8.12.1 --fail http://past-exam-api:8080/ping
```

## Caddy Cutover

Append the two reviewed site blocks from `deploy/Caddyfile.past-exam` to
`/home/opc/vaultwarden/Caddyfile`. Validate before reload:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
docker logs --since 5m caddy
```

Point the two formal DNS records to the Oracle host only when the private
upstream tests pass. Then test the public path, Google login, authenticated API,
R2 upload/download/delete, PDF rendering, and admin operations. Recheck
Vaultwarden after the reload.

## Automatic Main Deployment

The production host watches the frontend and backend GitHub `main` branches
directly. GitHub Releases and Git tags are not used. The systemd timer checks
once per minute and deploys only when either commit SHA changes.

Each change is built in the inactive `blue` or `green` slot. Caddy is reloaded
only after both new containers pass their health checks. The previous slot stays
available for fast rollback. A PostgreSQL dump and Caddyfile backup are created
before every traffic switch.

Install the scripts without enabling the timer:

```bash
./deploy/install-main-watch.sh
```

Run and inspect the first deployment, then enable the watcher:

```bash
/home/opc/past-exam-managed/bin/deploy-main.sh
sudo systemctl enable --now past-exam-main-watch.timer
systemctl list-timers past-exam-main-watch.timer
journalctl -u past-exam-main-watch.service --since today
```

Roll back to the previous healthy slot:

```bash
/home/opc/past-exam-managed/bin/rollback-main.sh
```

Database schema migrations are intentionally not run by the watcher. A commit
that changes the schema requires a reviewed PostgreSQL-compatible migration
before its application code is merged to `main`.

## Rollback

If Caddy routing or either application fails, restore the Caddyfile and reload
it. This does not delete the migrated PostgreSQL volume:

```bash
cp /home/opc/vaultwarden/Caddyfile.before-past-exam /home/opc/vaultwarden/Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose --env-file oracle.env -f docker-compose.oracle.yml stop frontend backend
```

## Backups

Redis is cache-only and intentionally has no persistence. Configure encrypted,
off-host PostgreSQL backups with retention and restore tests before cutover.
Docker volumes alone are not backups.
