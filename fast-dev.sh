#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="compose.yml"
ENV_FILE=".env"

compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

echo "--- starting local dev dependencies"
compose up -d db redis

echo
echo "--- dependency status"
compose ps db redis

cat <<'EOF'

Fast local loop:

1. Backend
   cd backend
   uv sync --extra dev
   uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

2. Frontend
   cd frontend
   npm install
   npm run dev

Open:
  Frontend: http://localhost:3000
  Backend:  http://localhost:8000

Stop dependencies later with:
  docker compose -f compose.yml --env-file .env down
EOF
