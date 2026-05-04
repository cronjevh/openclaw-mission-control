#!/usr/bin/env bash
# Mission Control — PostgreSQL daily backup
# 7-day rolling backups pushed to GitHub: https://github.com/tfsmrt/mc-backups

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
FILE="$BACKUP_DIR/mc_backup_$TIMESTAMP.sql.gz"
KEEP_DAYS=7

mkdir -p "$BACKUP_DIR"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting backup → $FILE"

docker exec openclaw-mission-control-db-1 \
  pg_dump -U postgres mission_control \
  | gzip > "$FILE"

SIZE=$(du -sh "$FILE" | cut -f1)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backup complete — $SIZE"

# Remove local + git-tracked backups older than KEEP_DAYS
cd "$BACKUP_DIR"
OLD_FILES=$(find . -name "mc_backup_*.sql.gz" -mtime +$KEEP_DAYS)
if [ -n "$OLD_FILES" ]; then
  echo "$OLD_FILES" | xargs git rm --force
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Removed old backups: $OLD_FILES"
fi

# # Commit new backup + any deletions
# git add "$(basename "$FILE")"
# git -c user.email="edith@somrat.tech" -c user.name="EDITH" \
#   commit -m "backup: $TIMESTAMP ($SIZE)"
# git push origin main

# echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pushed to https://github.com/tfsmrt/mc-backups"
