#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: mission-control-cron-runner.sh -- <command> [args...]" >&2
}

if [[ "${1:-}" != "--" ]]; then
  usage
  exit 64
fi
shift

if [[ "$#" -eq 0 ]]; then
  usage
  exit 64
fi

lock_file="${MC_CRON_GATE_LOCK_FILE:-/tmp/mission-control-api-cron.lock}"
lock_wait_seconds="${MC_CRON_GATE_LOCK_WAIT_SECONDS:-3600}"
jitter_max_seconds="${MC_CRON_GATE_JITTER_MAX_SECONDS:-20}"
retry_count="${MC_CRON_GATE_RETRY_COUNT:-3}"
retry_base_seconds="${MC_CRON_GATE_RETRY_BASE_SECONDS:-30}"
cooldown_seconds="${MC_CRON_GATE_COOLDOWN_SECONDS:-10}"

timestamp() {
  date --iso-8601=seconds
}

sleep_jitter() {
  if [[ "$jitter_max_seconds" =~ ^[0-9]+$ ]] && (( jitter_max_seconds > 0 )); then
    sleep_seconds=$(( RANDOM % (jitter_max_seconds + 1) ))
    if (( sleep_seconds > 0 )); then
      echo "[$(timestamp)] cron gate jitter ${sleep_seconds}s"
      sleep "$sleep_seconds"
    fi
  fi
}

is_rate_limit_output_file() {
  grep -Eiq 'HTTP 429|Too Many Requests|status code[^[:cntrl:]]*429|status[:=][[:space:]]*429' "$1"
}

mkdir -p "$(dirname "$lock_file")"
sleep_jitter

exec 9>"$lock_file"
if ! flock -w "$lock_wait_seconds" 9; then
  echo "[$(timestamp)] cron gate failed to acquire lock after ${lock_wait_seconds}s: $lock_file" >&2
  exit 75
fi

attempt=1
while :; do
  echo "[$(timestamp)] cron gate starting attempt ${attempt}: $*"
  output_file="$(mktemp)"
  "$@" 2>&1 | tee "$output_file"
  status=${PIPESTATUS[0]}

  if (( status == 0 )); then
    rm -f "$output_file"
    if [[ "$cooldown_seconds" =~ ^[0-9]+$ ]] && (( cooldown_seconds > 0 )); then
      echo "[$(timestamp)] cron gate cooldown ${cooldown_seconds}s"
      sleep "$cooldown_seconds"
    fi
    echo "[$(timestamp)] cron gate complete"
    exit 0
  fi

  if (( attempt >= retry_count )) || ! is_rate_limit_output_file "$output_file"; then
    rm -f "$output_file"
    echo "[$(timestamp)] cron gate failed with exit ${status}"
    exit "$status"
  fi

  rm -f "$output_file"
  sleep_seconds=$(( retry_base_seconds * attempt ))
  echo "[$(timestamp)] cron gate saw HTTP 429; retrying in ${sleep_seconds}s"
  sleep "$sleep_seconds"
  attempt=$(( attempt + 1 ))
done
