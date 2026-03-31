#!/bin/bash
set -e

echo "=== NTPU Past Exam — Local Dev Bootstrap ==="
echo ""

# --- Clone sub-repos if missing ---
if [ ! -d "ntpu-past-exam" ]; then
  echo "Cloning frontend..."
  git clone git@github.com:NTPU-Tools/ntpu-past-exam.git
else
  echo "Frontend repo already exists, skipping clone."
fi

if [ ! -d "ntpu-past-exam-service" ]; then
  echo "Cloning backend..."
  git clone git@github.com:NTPU-Tools/ntpu-past-exam-service.git
else
  echo "Backend repo already exists, skipping clone."
fi

echo ""

# --- Create env files if missing ---
if [ ! -f "ntpu-past-exam-service/.env" ]; then
  cp ntpu-past-exam-service/.env.example ntpu-past-exam-service/.env
  echo "Created backend .env"
else
  echo "Backend .env already exists, skipping."
fi

if [ ! -f "ntpu-past-exam/.env" ]; then
  cp ntpu-past-exam/.env.example ntpu-past-exam/.env
  echo "Created frontend .env"
else
  echo "Frontend .env already exists, skipping."
fi

echo ""

# --- Start Docker services ---
echo "Starting Docker services..."
docker compose up --build -d

echo ""
echo "Waiting for backend to be ready..."
until docker compose exec -T backend python -c "from sql.database import SessionLocal; SessionLocal().close()" 2>/dev/null; do
  sleep 2
done
echo "Backend is ready."

echo ""

# --- Seed database ---
echo "Seeding database..."
docker compose exec -T backend python scripts/seed.py

echo ""
echo "=== Done! ==="
echo ""
echo "  Frontend:      http://localhost:3000"
echo "  Backend API:   http://localhost:8080"
echo "  MinIO Console: http://localhost:9001  (minioadmin / minioadmin)"
echo ""
echo "  Login (click 20x on login page to toggle username/password mode):"
echo "    admin    / admin123      (super user)"
echo "    student1 / password123   (regular user)"
echo "    student2 / password123   (regular user)"
echo ""
echo "  Logs:  docker compose logs -f"
echo "  Stop:  docker compose down"
echo "  Reset: docker compose down -v && ./bootstrap.sh"
