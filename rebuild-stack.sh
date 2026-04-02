#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="compose.yml"
ENV_FILE=".env"
DOWN_TIMEOUT_SECONDS="${DOWN_TIMEOUT_SECONDS:-10}"
COMPOSE_PROGRESS_MODE="${COMPOSE_PROGRESS_MODE:-plain}"

cleanup() {
  if [[ -n "${TEMP_DOCKER_CONFIG_DIR:-}" && -d "${TEMP_DOCKER_CONFIG_DIR}" ]]; then
    rm -rf "${TEMP_DOCKER_CONFIG_DIR}"
  fi
}

prepare_docker_config() {
  local docker_config_root="${DOCKER_CONFIG:-$HOME/.docker}"
  local docker_config_file="${docker_config_root}/config.json"

  if [[ ! -f "${docker_config_file}" ]]; then
    return
  fi

  local creds_store
  creds_store="$(
    python3 - "${docker_config_file}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("credsStore", ""))
PY
  )"

  if [[ -z "${creds_store}" ]]; then
    return
  fi

  local helper_bin="docker-credential-${creds_store}"
  if command -v "${helper_bin}" >/dev/null 2>&1 && "${helper_bin}" list >/dev/null 2>&1; then
    return
  fi

  TEMP_DOCKER_CONFIG_DIR="$(mktemp -d)"
  python3 - "${docker_config_file}" "${TEMP_DOCKER_CONFIG_DIR}/config.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data.pop("credsStore", None)

cred_helpers = data.get("credHelpers")
if isinstance(cred_helpers, dict):
    filtered = {
        registry: helper
        for registry, helper in cred_helpers.items()
        if not str(helper).endswith(".exe")
    }
    if filtered:
        data["credHelpers"] = filtered
    else:
        data.pop("credHelpers", None)

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
  export DOCKER_CONFIG="${TEMP_DOCKER_CONFIG_DIR}"
  echo "--- using sanitized Docker config (credential helper '${creds_store}' unavailable on this host)"
}

trap cleanup EXIT
prepare_docker_config

compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

echo "--- checking existing stack"
running_container_ids="$(compose ps -q 2>/dev/null || true)"
if [[ -n "${running_container_ids}" ]]; then
  echo "--- stopping existing stack (timeout: ${DOWN_TIMEOUT_SECONDS}s)"
  compose down --remove-orphans --timeout "${DOWN_TIMEOUT_SECONDS}"
else
  echo "--- no existing compose-managed containers found; skipping shutdown"
fi

echo "--- rebuilding images and starting (progress: ${COMPOSE_PROGRESS_MODE})"
compose --progress "${COMPOSE_PROGRESS_MODE}" up -d --build

echo "--- tailing backend logs (ctrl+c to exit)"
compose logs -f --no-log-prefix backend
