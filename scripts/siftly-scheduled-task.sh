#!/bin/bash
set -u

ROOT="/Users/takahiro/Projects/Siftly"
BASE_URL="${SIFTLY_BASE_URL:-http://localhost:15000}"
MODE="${1:-}"
LOG_PREFIX="[siftly-scheduled:${MODE:-unknown}]"

log() {
  printf '%s %s\n' "$LOG_PREFIX" "$*"
}

read_env_value() {
  local key="$1"
  local value
  value=$(sed -n "s/^${key}=//p" "$ROOT/.env" 2>/dev/null | tail -n 1)
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "$value"
}

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-$(read_env_value DISCORD_WEBHOOK_URL)}"
SIFTLY_USERNAME="${SIFTLY_USERNAME:-$(read_env_value SIFTLY_USERNAME)}"
SIFTLY_PASSWORD="${SIFTLY_PASSWORD:-$(read_env_value SIFTLY_PASSWORD)}"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"

curl_auth_args=()
if [[ -n "$SIFTLY_USERNAME" && -n "$SIFTLY_PASSWORD" ]]; then
  curl_auth_args+=(--user "$SIFTLY_USERNAME:$SIFTLY_PASSWORD")
fi

request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local args=(--silent --show-error --fail-with-body --max-time 1800 "${curl_auth_args[@]}" -X "$method" "$BASE_URL$path")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  curl "${args[@]}"
}

notify() {
  local message="$1"
  [[ -z "$DISCORD_WEBHOOK_URL" ]] && { log 'Discord webhook is not configured'; return 0; }
  [[ -z "$NODE_BIN" ]] && { log 'node is not available; cannot encode Discord payload'; return 0; }

  local payload
  payload=$("$NODE_BIN" -e 'console.log(JSON.stringify({content: process.argv[1]}))' "$message") || return 0
  curl --silent --show-error --max-time 30 -X POST \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$DISCORD_WEBHOOK_URL" >/dev/null || log 'Discord notification failed'
}

json_summary() {
  local json="$1"
  [[ -z "$NODE_BIN" ]] && { printf 'unknown\t?\t?\t\t'; return 0; }
  "$NODE_BIN" -e '
    try {
      const value = JSON.parse(process.argv[1]);
      console.log([
        value.status ?? "unknown",
        value.done ?? "?",
        value.total ?? "?",
        value.lastError ?? "",
        value.error ?? "",
      ].join("\t").replace(/[\r\n]/g, " "));
    } catch {
      console.log("invalid\t?\t?\t\t");
    }
  ' "$json"
}

run_import() {
  local response
  log 'starting live import'
  if response=$(request POST /api/import/x-oauth/fetch '{"maxPages":10,"includeThreads":true}' 2>&1); then
    log "import result: $response"
    notify $'Siftly Xライブインポート完了\n'"$response"
    return 0
  fi

  log "import failed: $response"
  notify $'Siftly Xライブインポート失敗\n'"$response"
  return 1
}

run_categorize() {
  local start_response status_response summary pipeline_status done total last_error pipeline_error
  log 'starting AI categorization'
  if ! start_response=$(request POST /api/categorize '{"force":false,"language":"ja"}' 2>&1); then
    log "categorization start failed: $start_response"
    notify $'Siftly AI分類の開始に失敗\n'"$start_response"
    return 1
  fi

  log "categorization started: $start_response"
  local deadline=$((SECONDS + 21600))
  while (( SECONDS < deadline )); do
    if ! status_response=$(request GET /api/categorize 2>&1); then
      log "categorization status failed: $status_response"
      notify $'Siftly AI分類の状態確認に失敗\n'"$status_response"
      return 1
    fi

    summary=$(json_summary "$status_response")
    IFS=$'\t' read -r pipeline_status done total last_error pipeline_error <<< "$summary"
    if [[ "$pipeline_status" == 'idle' ]]; then
      if [[ -n "$pipeline_error" || -n "$last_error" ]]; then
        log "categorization finished with error: ${pipeline_error:-$last_error}"
        notify $'Siftly AI分類がエラー終了\n'"処理: ${done}/${total}"$'\n'"${pipeline_error:-$last_error}"
        return 1
      fi
      log "categorization complete: ${done}/${total}"
      notify $'Siftly AI分類完了\n'"処理: ${done}/${total}"
      return 0
    fi
    sleep 10
  done

  log 'categorization timed out after 6 hours'
  notify 'Siftly AI分類が6時間でタイムアウトしました'
  return 1
}

if [[ "${SIFTLY_SCHEDULED_DRY_RUN:-0}" == '1' ]]; then
  log "dry-run: base URL $BASE_URL"
  log "dry-run: Discord webhook $([[ -n "$DISCORD_WEBHOOK_URL" ]] && echo configured || echo missing)"
  exit 0
fi

case "$MODE" in
  import) run_import ;;
  categorize) run_categorize ;;
  *)
    echo "usage: $0 import|categorize" >&2
    exit 2
    ;;
esac
