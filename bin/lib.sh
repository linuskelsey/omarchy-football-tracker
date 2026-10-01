#!/usr/bin/env bash
# Shared helpers for the football-tracker plugin backend scripts.
# Sourced by poll.sh and setup.sh — not meant to be run directly.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$PLUGIN_DIR/icons"

CONFIG_DIR="$HOME/.config/omarchy-football-tracker"
STATE_DIR="$HOME/.local/state/omarchy-football-tracker"
CONFIG_FILE="$CONFIG_DIR/config.json"
API_KEY_FILE="$CONFIG_DIR/api_key"
STATE_FILE="$STATE_DIR/state.json"
FIXTURES_CACHE="$STATE_DIR/fixtures_cache.json"

API_BASE="https://v3.football.api-sports.io"

# Adaptive live-polling budget (see poll.sh): a free API-Football plan
# allows 100 requests/day; reserve a couple for the once-daily fixture
# cache refresh and spend the rest on live-match checks (2 calls each).
API_DAILY_BUDGET=100
FIXTURE_CACHE_CALLS_PER_DAY=2

mkdir -p "$CONFIG_DIR" "$STATE_DIR"

ft_log() {
  echo "[football-tracker] $*" >&2
}

ft_api_key() {
  if [[ -f "$API_KEY_FILE" ]]; then
    cat "$API_KEY_FILE"
  fi
}

# ft_api <path-with-query>  e.g. ft_api "fixtures?live=all"
ft_api() {
  local path="$1"
  local key
  key="$(ft_api_key)"
  if [[ -z "$key" ]]; then
    ft_log "no API key configured (run setup.sh)"
    return 1
  fi
  local attempt body code
  for attempt in 1 2 3; do
    body="$(curl -sS --max-time 15 -w '\n%{http_code}' \
      -H "x-apisports-key: $key" \
      "$API_BASE/$path")"
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "$code" == "429" ]]; then
      ft_log "rate limited (attempt $attempt), backing off"
      sleep $((attempt * 8))
      continue
    fi
    printf '%s' "$body"
    return 0
  done
  ft_log "gave up after repeated rate limiting: $path"
  return 1
}

# ft_notify <headline> <body> <icon-file> [urgency] [glyph]
ft_notify() {
  local headline="$1" body="$2" icon_file="$3" urgency="${4:-normal}"
  local icon_path="$ICON_DIR/$icon_file"
  omarchy notification send \
    --app-name "Football Tracker" \
    -u "$urgency" \
    -i "$icon_path" \
    "$headline" "$body"
}

# ft_icon_for_event <event-type> <detail>
# event-type: Goal | Card | subst | Var
ft_icon_for_event() {
  local type="$1" detail="${2:-}"
  case "$type" in
    Goal)
      case "$detail" in
        *Own*) echo "own-goal.svg" ;;
        *Missed*) echo "penalty-miss.svg" ;;
        *) echo "goal.svg" ;;
      esac
      ;;
    Card)
      case "$detail" in
        *Red*) echo "card-red.svg" ;;
        *) echo "card-yellow.svg" ;;
      esac
      ;;
    subst) echo "substitution.svg" ;;
    *) echo "whistle.svg" ;;
  esac
}

ft_read_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    cat "$CONFIG_FILE"
  else
    echo '{"poll_interval_live_seconds":180,"live_poll_mode":"auto","teams":[],"has_api_key":false}'
  fi
}

# ft_write_config <teams-json-array> <poll-interval-seconds> [live-poll-mode]
# live-poll-mode: "auto" (default — see poll.sh's adaptive calculation) or
# "manual" (always use <poll-interval-seconds> as the live-check interval).
ft_write_config() {
  local teams="$1" interval="$2" mode="${3:-auto}" has_key="false"
  [[ -s "$API_KEY_FILE" ]] && has_key="true"
  jq -n --argjson teams "$teams" --argjson interval "$interval" --arg mode "$mode" --argjson has_api_key "$has_key" \
    '{teams:$teams, poll_interval_live_seconds:$interval, live_poll_mode:$mode, has_api_key:$has_api_key}' > "$CONFIG_FILE"
}

ft_write_state() {
  # ft_write_state <json>
  if [[ -z "${1//[[:space:]]/}" ]] || ! jq empty <<<"$1" >/dev/null 2>&1; then
    ft_log "ft_write_state: refusing to write empty/invalid JSON, keeping previous state.json"
    return 1
  fi
  local tmp="$STATE_FILE.tmp.$$"
  echo "$1" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
