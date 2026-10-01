#!/usr/bin/env bash
# Non-interactive settings save, called from the bar widget's popup GUI
# (BarWidget.qml's Save button, via bar.run). Not meant to be run by hand
# for routine use — bin/setup.sh is the interactive equivalent with live
# team search.
#
# Usage: save-settings.sh [--api-key <key>] [--teams <comma,separated,names>]
#
# --api-key, if given and non-empty, replaces the stored key.
# --teams, if given, REPLACES the favorite-teams list: each name is matched
# against your current list first (case-insensitive, keeps the existing
# team/id so nothing is re-resolved unnecessarily), then any unmatched name
# is resolved via a live API-Football team search (best/exact match wins).
# Dropping a name from the list removes that team. A notification reports
# what was matched, added, or not found.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

new_api_key=""
new_teams=""
have_teams_arg=0
new_live_poll_mode=""
new_live_poll_interval=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) new_api_key="${2:-}"; shift 2 ;;
    --teams) new_teams="${2:-}"; have_teams_arg=1; shift 2 ;;
    --live-poll-mode) new_live_poll_mode="${2:-}"; shift 2 ;;
    --live-poll-interval) new_live_poll_interval="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "$new_api_key" ]]; then
  umask 077
  printf '%s' "$new_api_key" > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  ft_log "API key updated"
fi

if [[ "$have_teams_arg" -eq 1 ]]; then
  if [[ -z "$(ft_api_key)" ]]; then
    ft_notify "Football Tracker" "No API key set yet — add one before adding teams." "whistle.svg" "normal"
    exit 0
  fi

  config="$(ft_read_config)"
  existing_teams="$(jq -c '.teams // []' <<<"$config")"
  interval="$(jq -r '.poll_interval_live_seconds // 180' <<<"$config")"
  mode="$(jq -r '.live_poll_mode // "auto"' <<<"$config")"

  # Desired names, trimmed, empty entries dropped, in the order given.
  desired_names="$(printf '%s' "$new_teams" | jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

  resolved="[]"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    match="$(jq -c --arg n "$name" 'map(select((.name // "") | ascii_downcase == ($n | ascii_downcase))) | .[0] // empty' <<<"$existing_teams")"
    if [[ -n "$match" && "$match" != "null" ]]; then
      resolved="$(jq -c --argjson r "$resolved" --argjson t "$match" '$r + [$t]' <<<null)"
      continue
    fi

    resp="$(ft_api "teams?search=$(jq -rn --arg s "$name" '$s|@uri')")"
    count="$(jq '.response | length' <<<"$resp" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
      ft_notify "Team not found" "No match for \"$name\" — check the spelling." "whistle.svg" "normal"
      continue
    fi

    # Prefer an exact case-insensitive name match; else take the first result.
    picked="$(jq -c --arg n "$name" '
      (.response | map(.team) | map(select((.name // "") | ascii_downcase == ($n | ascii_downcase))) | .[0])
      // .response[0].team' <<<"$resp")"
    pname="$(jq -r '.name' <<<"$picked")"
    pcountry="$(jq -r '.country' <<<"$picked")"
    resolved="$(jq -c --argjson r "$resolved" --argjson t "$(jq -c '{id:.id, name:.name, country:.country}' <<<"$picked")" '$r + [$t]' <<<null)"
    ft_notify "Added $pname" "$pcountry — matched from \"$name\"" "goal.svg" "normal"
  done < <(jq -r '.[]' <<<"$desired_names")

  ft_write_config "$resolved" "$interval" "$mode"

  # Force the cache to refresh on the next poll now that the roster changed.
  rm -f "$FIXTURES_CACHE"

  ft_log "teams updated: $(jq -r '[.[].name] | join(", ")' <<<"$resolved")"
elif [[ -n "$new_api_key" ]]; then
  # Teams weren't touched this call, but the has_api_key flag still needs
  # to reflect the key we just wrote above.
  config="$(ft_read_config)"
  ft_write_config "$(jq -c '.teams // []' <<<"$config")" \
    "$(jq -r '.poll_interval_live_seconds // 180' <<<"$config")" \
    "$(jq -r '.live_poll_mode // "auto"' <<<"$config")"
fi

if [[ -n "$new_live_poll_mode" || -n "$new_live_poll_interval" ]]; then
  config="$(ft_read_config)"
  mode="${new_live_poll_mode:-$(jq -r '.live_poll_mode // "auto"' <<<"$config")}"
  interval="${new_live_poll_interval:-$(jq -r '.poll_interval_live_seconds // 180' <<<"$config")}"
  ft_write_config "$(jq -c '.teams // []' <<<"$config")" "$interval" "$mode"
  ft_log "live poll mode set to $mode (manual interval: ${interval}s)"
fi
