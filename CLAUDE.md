# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NTPU Past Exam (北大考古題) — a platform for National Taipei University students to upload, share, and browse past exam papers. The repo is a monorepo containing two independent sub-projects, each with its own git history:

- **`ntpu-past-exam/`** — Next.js 14 frontend (Pages Router)
- **`ntpu-past-exam-service/`** — FastAPI backend

## Frontend (`ntpu-past-exam/`)

### Commands

```bash
pnpm dev          # Start dev server (localhost:3000)
pnpm build        # Production build (standalone output)
pnpm lint         # ESLint
```

Package manager is **pnpm** (v9.12.2). Do not use npm or yarn.

### Tech Stack

- **Next.js 14** with **Pages Router** (not App Router) — routes live in `pages/`
- **TypeScript**, **Tailwind CSS**, **shadcn/ui** (Radix UI primitives)
- **SWR** for data fetching, **Axios** for HTTP, **Zustand** for global state
- **React Hook Form** + **Zod** for form validation
- **react-pdf** for PDF viewing
- **Google OAuth** (`@react-oauth/google`) for authentication
- Deployed on **Zeabur**

### Architecture

- **Routing**: `pages/[department_id]/[course_id]/[post_id].tsx` — department → course → post (PDF viewer)
- **Admin routes**: `pages/admin/[admin_department_id]/index.tsx`
- **Auth flow**: Google OAuth code → `POST /exchange` → JWT tokens stored in cookies (`ntpu-past-exam-access-token`, `ntpu-past-exam-refresh-token`). `middleware.ts` calls `/verify-token` server-side to protect routes.
- **API client** (`api-client/instance.ts`): Axios instance with interceptor that auto-refreshes expired tokens on 401.
- **Dialogs** (`containers/Dialogs/`): State controlled via `router.query` params (e.g., `?open_create_post_dialog=true`), mounted globally in `_app.tsx`.
- **Layout** (`components/Layout.tsx`): Resizable two-panel layout (sidebar + main) using `react-resizable-panels`. Simple layout for `/` and `/login`.
- **Stores**: `store/userStore.ts` (user data), `store/globalUiStateStore.ts` (panel width).
- **Schemas** (`schemas/`): Zod schemas for login, user, course, post, bulletin forms.
- **Custom hook**: `hooks/useDepartmentCourse.ts` — fetches and groups courses by category.

### Environment Variables

```
NEXT_PUBLIC_API_ORIGIN          # Backend URL (client-side)
API_ORIGIN                      # Backend URL (server-side, used in middleware)
NEXT_PUBLIC_GOOGLE_LOGIN_CLIENT_ID
NEXT_PUBLIC_GA_MEASUREMENT_ID
NEXT_PUBLIC_CLARITY_MEASUREMENT_ID
```

## Backend (`ntpu-past-exam-service/`)

### Commands

```bash
poetry install                    # Install dependencies
uvicorn main:app --reload         # Start dev server
alembic upgrade head              # Run migrations
alembic revision --autogenerate -m "msg"  # Create migration
```

Uses **Poetry** for dependency management. `requirements.txt` is an export for deployment.

### Tech Stack

- **FastAPI** with async endpoints
- **SQLAlchemy 2.0** ORM + **MySQL** + **Alembic** migrations
- **Redis** caching via `fastapi-cache2` (pickle serialization)
- **Cloudflare R2** (S3-compatible) for file storage via boto3
- **JWT** auth (HS256, python-jose) with access (1 day) / refresh (365 day) tokens
- **Logtail** for logging (Better Stack)
- Deployed on **Zeabur**

### Architecture

Feature-based module organization — each module has `router.py`, `dependencies.py`, `models.py`, and optionally `schemas.py`:

- **`auth/`** — Login via Google OAuth or NTPU LMS scraping (BeautifulSoup), JWT token management
- **`users/`** — User CRUD, department membership management
- **`departments/`** — Department management, join request approval flow
- **`courses/`** — Course CRUD scoped to departments
- **`posts/`** — Exam post CRUD with file upload to R2, status approval workflow
- **`bulletins/`** — Department announcements
- **`sql/`** — Database engine config, `BaseColumn` (UUID pk + timestamps for all models)
- **`static_file/r2.py`** — R2 client setup
- **`utils/`** — JWT helpers, email, logging middleware, exception handlers

### Authorization Model

Three middleware levels: `auth_middleware` (valid JWT), `admin_middleware` (department admin via path param), `super_user_middleware` (superuser flag in JWT).

- JWT payload includes `isu` (is_super_user) and `adm` (JSON array of admin department IDs)
- Posts auto-approved in public departments, require admin approval in private ones
- Department access: join request → admin approval flow
- Anonymous posts: `is_anonymous` flag hides owner info in responses

### Key Environment Variables

```
DATABASE_HOST, DATABASE_USERNAME, DATABASE_PASSWORD, DATABASE, DATABASE_PORT
REDIS_HOST, REDIS_PORT, REDIS_PASSWORD
R2_ACCESS_TOKEN, R2_ACCESS_KEY, R2_URL, R2_BUCKET_NAME, R2_FILE_PATH
HASH_KEY                        # JWT secret
ORIGIN                          # CORS allowed origin
GOOGLE_SERVICE_CLIENT_ID, GOOGLE_SERVICE_SERCET
```

### CORS Origins

`past-exam.zeabur.app`, `past-exam.ntpu.cc`, `past-exam.ntpu.xyz`, `localhost:3000`, `localhost:8080`

## Code Quality

- **Frontend**: ESLint (Airbnb + Next.js + Prettier), import sorting via `@trivago/prettier-plugin-sort-imports`
- **Backend**: Black, isort, pylint, pre-commit hooks (see `.pre-commit-config.yaml`)
