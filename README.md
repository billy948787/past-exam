# NTPU Past Exam 北大考古題

A platform for National Taipei University students to upload, share, and browse past exam papers — organized by department and course.

## Architecture

| Component | Tech | Directory |
|-----------|------|-----------|
| Frontend | Next.js 14 (Pages Router), TypeScript, Tailwind, shadcn/ui | `ntpu-past-exam/` |
| Backend | FastAPI, SQLAlchemy 2.0, Alembic | `ntpu-past-exam-service/` |
| Database | MySQL 8.0 | — |
| Cache | Redis 7 | — |
| File Storage | Cloudflare R2 (MinIO locally) | — |

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

### Access

| Service | URL |
|---------|-----|
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:8080 |
| MinIO Console (S3) | http://localhost:9001 |

### Test Accounts

Log in using username/password mode (click 20 times on the login page to toggle the input fields).

| User | Password | Role |
|------|----------|------|
| `admin` | `admin123` | Super user, admin of all departments |
| `student1` | `password123` | Regular user, member of 資工系 |
| `student2` | `password123` | Regular user, member of 電機系 |

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

All services are deployed on [Zeabur](https://zeabur.com):

| Component | Service |
|-----------|---------|
| Frontend | Next.js (standalone) |
| Backend | FastAPI (Python) |
| Database | MySQL |
| Cache | Redis |
| File Storage | Cloudflare R2 |
