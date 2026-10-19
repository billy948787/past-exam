# NTPU Past Exam 北大考古題

A platform for National Taipei University students to upload, share, and browse past exam papers — organized by department and course.

## Architecture

| Component    | Tech                                                       | Directory                 |
| ------------ | ---------------------------------------------------------- | ------------------------- |
| Frontend     | Vite, React, TypeScript, Tailwind, shadcn/ui               | `ntpu-past-exam/`         |
| Backend      | FastAPI, SQLAlchemy 2.0, Alembic                           | `ntpu-past-exam-service/` |
| Database     | MySQL 8.0 (local), PostgreSQL 17 (Oracle production)       | —                         |
| Cache        | Redis 7                                                    | —                         |
| File Storage | Cloudflare R2 (MinIO locally)                              | —                         |

## Local Development

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose

### Setup

```bash
# 1. Clone the repo
git clone <root-repo-url> past-exam
cd past-exam

# 2. One-command setup (clones sub-repos, creates .env, starts Docker, seeds DB)
./bootstrap.sh
```

`bootstrap.sh` only builds Docker images on the **first run**. Subsequent runs skip the build step and start existing images directly.

### Access

| Service            | URL                   |
| ------------------ | --------------------- |
| Frontend           | http://localhost:5173 |
| Backend API        | http://localhost:8080 |
| MinIO Console (S3) | http://localhost:9001 |

### Test Accounts

Log in using username/password mode (click 20 times on the login page to toggle the input fields).

| User       | Password      | Role                                 |
| ---------- | ------------- | ------------------------------------ |
| `admin`    | `admin123`    | Super user, admin of all departments |
| `student1` | `password123` | Regular user, member of 資工系       |
| `student2` | `password123` | Regular user, member of 電機系       |

### Useful Commands

```bash
# Stop services
docker compose down

# Stop and wipe all data
docker compose down -v

# View backend logs
docker compose logs -f backend

# Run alembic migration (for production schema changes)
docker compose exec backend alembic revision --autogenerate -m "description"
docker compose exec backend alembic upgrade head

# Re-seed (wipe data first)
docker compose down -v && docker compose up -d
docker compose exec backend python scripts/seed.py

# Rebuild images after Dockerfile or dependency changes (uses layer cache)
docker compose build

# Force a full rebuild from scratch
docker compose build --no-cache

# Destroy images and let bootstrap.sh rebuild on next run
docker compose down --rmi local
```

### Test On Phone/Tablet (Real Device)

To test mobile-only behaviors (for example, PDF download side effects), run the stack with a LAN IP instead of localhost.

```bash
# Pick your Mac IP (example)
export HOST_IP=192.168.1.23

# Start/restart with HOST_IP applied
docker compose down
docker compose up -d --build
```

Then open `http://$HOST_IP:5173` on your phone/tablet (same Wi-Fi).

- Frontend API origin becomes `http://$HOST_IP:8080`
- Backend file URLs become `http://$HOST_IP:9000/past-exam/...`
- CORS also allows `ORIGIN=http://$HOST_IP:5173`

If you want default localhost behavior again, unset the variable and restart:

```bash
unset HOST_IP
docker compose down
docker compose up -d
```

### Running Without Docker

If you prefer running the apps natively (requires MySQL, Redis, and MinIO/S3 running separately):

**Backend:**

```bash
cd ntpu-past-exam-service
poetry install
uvicorn main:app --reload --port 8080
```

**Frontend:**

```bash
cd ntpu-past-exam
pnpm install
pnpm dev
```

## Deployment

Oracle self-hosting files are documented in `deploy/README.oracle.md` and use
`docker-compose.oracle.yml`. The production stack keeps Cloudflare R2 and runs
PostgreSQL and Redis on a private Docker network behind the existing Caddy.

The legacy Zeabur deployment is described below.

All services are deployed on [Zeabur](https://zeabur.com):

| Component    | Service              |
| ------------ | -------------------- |
| Frontend     | Next.js (standalone) |
| Backend      | FastAPI (Python)     |
| Database     | MySQL                |
| Cache        | Redis                |
| File Storage | Cloudflare R2        |

[![Deployed on Zeabur](https://zeabur.com/deployed-on-zeabur-dark.svg)](https://zeabur.com/referral?referralCode=f312213213&utm_source=f312213213&utm_campaign=oss)
