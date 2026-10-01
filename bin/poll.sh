#!/usr/bin/env bash
# Backend poller for the football-tracker plugin.
# Invoked periodically by the omarchy-football-tracker systemd --user timer.
# Writes ~/.local/state/omarchy-football-tracker/state.json for the QML bar
# widget to read, and fires desktop notifications for match-day / kickoff /
# live-event moments.
#
# Usage: poll.sh [--simulate]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SIMULATE=0
[[ "${1:-}" == "--simulate" ]] && SIMULATE=1

NOW_EPOCH="$(date -u +%s)"
TODAY="$(date -u +%Y-%m-%d)"

# --- bookkeeping (dedup) lives inside the same state file, under "_bookkeeping" ---
load_bookkeeping() {
  local bk="{}"
  if [[ -f "$STATE_FILE" ]]; then
    bk="$(jq -c '._bookkeeping // {}' "$STATE_FILE" 2>/dev/null)"
  fi
  [[ -z "$bk" ]] && bk='{}'
  echo "$bk"
}

if [[ "$SIMULATE" -eq 1 ]]; then
  ft_log "SIMULATE mode: seeding a fake live match + events, no API calls made"
  ft_notify "Liverpool play today" "Liverpool vs Arsenal — 19:00 kickoff (Premier League)" "calendar.svg" "normal"
  sleep 1
  ft_notify "Kickoff in 15 minutes" "Liverpool vs Arsenal kicks off soon (Premier League)" "whistle.svg" "normal"
  sleep 1
  ft_notify "Kickoff! Liverpool vs Arsenal" "0 - 0 (Premier League)" "whistle.svg" "normal"
  sleep 1
  ft_notify "GOAL! Liverpool 1-0 Arsenal" "23' Salah (Normal Goal)" "goal.svg" "critical"
  sleep 1
  ft_notify "Yellow card — Arsenal" "30' Saka" "card-yellow.svg" "normal"

  state=$(jq -n '{
    updated_at: (now | todateiso8601),
    next_match: null,
    live_match: {
      fixture_id: 999999, team: "Liverpool", opponent: "Arsenal",
      team_score: 1, opponent_score: 0, elapsed: 34, status: "1H", competition: "Premier League"
    },
    recent_events: [
      {type:"Goal", minute:23, team:"Liverpool", player:"Salah", detail:"Normal Goal", icon:"goal.svg"},
      {type:"Card", minute:30, team:"Arsenal", player:"Saka", detail:"Yellow Card", icon:"card-yellow.svg"}
    ],
    upcoming: [],
    _bookkeeping: {}
  }')
  ft_write_state "$state"
  ft_log "simulate: wrote sample state.json — check the bar widget now"
  exit 0
fi

config="$(ft_read_config)"
teams_json="$(jq -c '.teams // []' <<<"$config")"
team_count="$(jq 'length' <<<"$teams_json")"
live_interval="$(jq -r '.poll_interval_live_seconds // 180' <<<"$config")"

if [[ "$team_count" -eq 0 ]]; then
  ft_log "no favorite teams configured — run setup.sh"
  exit 0
fi

if [[ -z "$(ft_api_key)" ]]; then
  ft_log "no API key configured — run setup.sh"
  exit 0
fi

# --- refresh fixture cache once/day ---
cache_stale=1
if [[ -f "$FIXTURES_CACHE" ]]; then
  cache_date="$(jq -r '.fetched_date // ""' "$FIXTURES_CACHE" 2>/dev/null)"
  [[ "$cache_date" == "$TODAY" ]] && cache_stale=0
fi

if [[ "$cache_stale" -eq 1 ]]; then
  # The free API-Football plan rejects `next`/`last`, any non-2022-2024
  # `season` value, AND restricts the `date` parameter itself to a rolling
  # yesterday/today/tomorrow window (confirmed directly against the live
  # API: `date=<today+2>` is rejected with "Free plans do not have access
  # to this date, try from <yesterday> to <tomorrow>"). So on the free plan
  # there is no way to see a fixture more than ~1 day ahead, for any team,
  # through any endpoint. This only scans today+tomorrow accordingly — a
  # favorite team's match becomes visible the day before it happens, not
  # further out. (A paid plan lifts the date/season restriction if more
  # advance notice is wanted.)
  ft_log "refreshing fixture cache for $team_count team(s) (today+tomorrow)"
  team_ids="$(jq -c '[.[].id]' <<<"$teams_json")"
  all_fixtures="[]"
  fail_count=0
  day_count=0
  for offset in 0 1; do
    [[ "$offset" -gt 0 ]] && sleep 2
    day_count=$((day_count + 1))
    d="$(date -u -d "+${offset} day" +%Y-%m-%d)"
    resp="$(ft_api "fixtures?date=${d}")" || { ft_log "fixture fetch failed for $d"; fail_count=$((fail_count + 1)); continue; }
    api_err="$(jq -c '.errors // {}' <<<"$resp" 2>/dev/null)"
    [[ -n "$api_err" && "$api_err" != "{}" && "$api_err" != "[]" ]] && ft_log "API error for $d: $api_err"
    fx="$(jq -c --argjson ids "$team_ids" --argjson teams "$teams_json" '
      [.response[]? as $f
       | ($f.teams.home.id) as $hid | ($f.teams.away.id) as $aid
       | select(($ids | index($hid)) != null or ($ids | index($aid)) != null)
       | (if ($ids | index($hid)) != null then $hid else $aid end) as $myid
       | {
           team: ($teams[] | select(.id == $myid) | .name),
           team_id: $myid,
           fixture_id: $f.fixture.id,
           kickoff: $f.fixture.date,
           home: ($hid == $myid),
           opponent: (if $hid == $myid then $f.teams.away.name else $f.teams.home.name end),
           competition: $f.league.name
         }]' <<<"$resp" 2>/dev/null)"
    [[ -n "$fx" && "$fx" != "[]" ]] && all_fixtures="$(jq -c --argjson a "$all_fixtures" --argjson b "$fx" '$a + $b' <<<null)"
  done
  if [[ "$fail_count" -ge "$day_count" ]]; then
    ft_log "fixture cache refresh failed entirely ($fail_count/$day_count days) — leaving cache stale, will retry next poll"
  else
    jq -n --arg d "$TODAY" --argjson f "$all_fixtures" '{fetched_date:$d, fixtures:$f}' > "$FIXTURES_CACHE"
  fi
fi

fixtures="$(jq -c '.fixtures // []' "$FIXTURES_CACHE" 2>/dev/null || echo '[]')"

bookkeeping="$(load_bookkeeping)"
# recent_events only carries forward across polls while the SAME match is
# still live (so events accumulate through a match); otherwise it starts
# fresh, so cards from a finished/previous match don't linger in the popup
# forever once nothing is live.
prev_live_fixture_id="$([[ -f "$STATE_FILE" ]] && jq -r '.live_match.fixture_id // empty' "$STATE_FILE" 2>/dev/null)"
prev_live_match="$([[ -f "$STATE_FILE" ]] && jq -c '.live_match // null' "$STATE_FILE" 2>/dev/null || echo 'null')"
[[ -z "$prev_live_match" ]] && prev_live_match='null'
prev_recent_events="$([[ -f "$STATE_FILE" ]] && jq -c '.recent_events // []' "$STATE_FILE" 2>/dev/null || echo '[]')"
[[ -z "$prev_recent_events" ]] && prev_recent_events='[]'
recent_events='[]'

live_match="null"
next_match="$(jq -c 'sort_by(.kickoff) | .[0] // null' <<<"$fixtures")"

# fixtures happening today (local date match, UTC-based approximation)
todays="$(jq -c --arg today "$TODAY" '[.[] | select(.kickoff[0:10] == $today)]' <<<"$fixtures")"

while IFS= read -r fx; do
  [[ -z "$fx" || "$fx" == "null" ]] && continue
  fid="$(jq -r '.fixture_id' <<<"$fx")"
  kickoff="$(jq -r '.kickoff' <<<"$fx")"
  kickoff_epoch="$(date -u -d "$kickoff" +%s 2>/dev/null || echo 0)"
  [[ "$kickoff_epoch" -eq 0 ]] && continue
  mins_to_kickoff=$(( (kickoff_epoch - NOW_EPOCH) / 60 ))
  key="$fid"

  notified_day="$(jq -r --arg k "$key" '.[$k].day // false' <<<"$bookkeeping")"
  notified_15="$(jq -r --arg k "$key" '.[$k].t15 // false' <<<"$bookkeeping")"
  notified_ko="$(jq -r --arg k "$key" '.[$k].kickoff // false' <<<"$bookkeeping")"

  team="$(jq -r '.team' <<<"$fx")"; opp="$(jq -r '.opponent' <<<"$fx")"; comp="$(jq -r '.competition' <<<"$fx")"
  home="$(jq -r '.home // false' <<<"$fx")"
  ko_local="$(date -d "$kickoff" +%H:%M 2>/dev/null || echo "$kickoff")"

  if [[ "$notified_day" != "true" ]]; then
    ft_notify "$team play today" "$team vs $opp — $ko_local kickoff ($comp)" "calendar.svg" "normal"
    bookkeeping="$(jq -c --arg k "$key" '.[$k].day = true' <<<"$bookkeeping")"
  fi

  if [[ "$notified_15" != "true" && "$mins_to_kickoff" -le 15 && "$mins_to_kickoff" -ge 0 ]]; then
    ft_notify "Kickoff in 15 minutes" "$team vs $opp ($comp)" "whistle.svg" "normal"
    bookkeeping="$(jq -c --arg k "$key" '.[$k].t15 = true' <<<"$bookkeeping")"
  fi

  # live window: kickoff time through kickoff + 130 minutes
  if [[ "$NOW_EPOCH" -ge "$kickoff_epoch" && "$NOW_EPOCH" -le $((kickoff_epoch + 130*60)) ]]; then
    # Throttle to poll_interval_live_seconds: the systemd timer still fires
    # every 60s regardless, but a live match costs 2 API calls per check
    # (fixtures?live=all + fixtures/events), which blows through a free-plan
    # daily quota well before full time if we hit the API on every tick.
    # While waiting out the interval (or once quota's gone, see below), keep
    # showing the last known live score instead of silently reverting to the
    # static next_match/kickoff label, which reads as "hasn't started yet".
    last_live_check="$(jq -r --arg k "$key" '.[$k].live_check // 0' <<<"$bookkeeping")"
    due_for_check=1
    [[ "$last_live_check" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last_live_check < live_interval )) && due_for_check=0

    if [[ "$due_for_check" -eq 0 ]]; then
      if [[ "$prev_live_fixture_id" == "$fid" ]]; then
        live_match="$prev_live_match"
        recent_events="$prev_recent_events"
      fi
      continue_live_check=0
    else
      continue_live_check=1
    fi

    if [[ "$continue_live_check" -eq 1 ]]; then
    live_resp="$(ft_api "fixtures?live=all")" || live_resp=""
    live_api_err="$(jq -c '.errors // {}' <<<"$live_resp" 2>/dev/null)"
    if [[ -n "$live_api_err" && "$live_api_err" != "{}" && "$live_api_err" != "[]" ]]; then
      ft_log "live fixtures API error for $team vs $opp: $live_api_err"
    fi
    bookkeeping="$(jq -c --arg k "$key" --argjson t "$NOW_EPOCH" '.[$k].live_check = $t' <<<"$bookkeeping")"
    live_fx="$(jq -c --argjson fid "$fid" '.response[]? | select(.fixture.id == $fid)' <<<"$live_resp" 2>/dev/null)"

    if [[ -z "$live_fx" || "$live_fx" == "null" ]] && [[ -n "$live_api_err" && "$live_api_err" != "{}" && "$live_api_err" != "[]" ]] && [[ "$prev_live_fixture_id" == "$fid" ]]; then
      ft_log "keeping last known live score for $team vs $opp (API error, see above)"
      live_match="$prev_live_match"
      recent_events="$prev_recent_events"
    fi

    if [[ -n "$live_fx" && "$live_fx" != "null" ]]; then
      if [[ "$notified_ko" != "true" ]]; then
        ft_notify "Kickoff! $team vs $opp" "0 - 0 ($comp)" "whistle.svg" "normal"
        bookkeeping="$(jq -c --arg k "$key" '.[$k].kickoff = true' <<<"$bookkeeping")"
      fi

      home_score="$(jq -r '.goals.home // 0' <<<"$live_fx")"
      away_score="$(jq -r '.goals.away // 0' <<<"$live_fx")"
      elapsed="$(jq -r '.fixture.status.elapsed // 0' <<<"$live_fx")"
      status_short="$(jq -r '.fixture.status.short // ""' <<<"$live_fx")"

      # Store scores favorite-team-first so the bar/popup show the user's
      # team before the opponent regardless of home/away.
      if [[ "$home" == "true" ]]; then
        team_score="$home_score"
        opponent_score="$away_score"
      else
        team_score="$away_score"
        opponent_score="$home_score"
      fi

      live_match="$(jq -n --arg team "$team" --arg opp "$opp" --arg comp "$comp" \
        --argjson fid "$fid" --argjson ts "$team_score" --argjson os "$opponent_score" \
        --argjson el "$elapsed" --arg st "$status_short" \
        '{fixture_id:$fid, team:$team, opponent:$opp, team_score:$ts, opponent_score:$os, elapsed:$el, status:$st, competition:$comp}')"

      # Same match still live as last poll: keep showing its earlier events.
      # Different (or no previous) live match: start the feed fresh.
      if [[ "$prev_live_fixture_id" == "$fid" ]]; then
        recent_events="$prev_recent_events"
      fi

      events_resp="$(ft_api "fixtures/events?fixture=${fid}")" || events_resp=""
      seen_key="events_${fid}"
      seen="$(jq -c --arg k "$seen_key" '.[$k] // []' <<<"$bookkeeping")"

      new_events="[]"
      while IFS= read -r ev; do
        [[ -z "$ev" || "$ev" == "null" ]] && continue
        etype="$(jq -r '.type' <<<"$ev")"
        edetail="$(jq -r '.detail // ""' <<<"$ev")"
        emin="$(jq -r '.time.elapsed // 0' <<<"$ev")"
        eplayer="$(jq -r '.player.name // "Unknown"' <<<"$ev")"
        eteam="$(jq -r '.team.name // ""' <<<"$ev")"
        ekey="${emin}-${etype}-${edetail}-${eplayer}"

        already_seen="$(jq -r --arg k "$ekey" 'index($k) != null' <<<"$seen")"
        if [[ "$already_seen" != "true" ]]; then
          icon="$(ft_icon_for_event "$etype" "$edetail")"
          case "$etype" in
            Goal) headline="GOAL! $eteam" ; urgency="critical" ;;
            Card) headline="${edetail} — $eteam" ; urgency="normal" ;;
            subst) headline="Substitution — $eteam" ; urgency="low" ;;
            *) headline="$etype — $eteam" ; urgency="low" ;;
          esac
          ft_notify "$headline" "${emin}' $eplayer ($edetail)" "$icon" "$urgency"
          seen="$(jq -c --arg k "$ekey" '. + [$k]' <<<"$seen")"
          new_ev="$(jq -n --arg type "$etype" --argjson minute "$emin" --arg team "$eteam" \
            --arg player "$eplayer" --arg detail "$edetail" --arg icon "$icon" \
            '{type:$type, minute:$minute, team:$team, player:$player, detail:$detail, icon:$icon}')"
          new_events="$(jq -c --argjson a "$new_events" --argjson e "$new_ev" '$a + [$e]' <<<null)"
        fi
      done < <(jq -c '.response[]?' <<<"$events_resp" 2>/dev/null)

      bookkeeping="$(jq -c --arg k "$seen_key" --argjson s "$seen" '.[$k] = $s' <<<"$bookkeeping")"
      recent_events="$(jq -c --argjson old "$recent_events" --argjson new "$new_events" '($new + $old) | .[0:20]' <<<null)"

      if [[ "$status_short" =~ ^(FT|AET|PEN)$ ]]; then
        ft_notify "Full time: $team $team_score-$opponent_score $opp" "$comp" "whistle.svg" "normal"
      fi
    fi
    fi
  fi
done < <(jq -c '.[]' <<<"$todays")

state="$(jq -n \
  --argjson next "$next_match" --argjson live "$live_match" \
  --argjson recent "$recent_events" --argjson upcoming "$fixtures" \
  --argjson bk "$bookkeeping" \
  '{updated_at: (now | todateiso8601), next_match: $next, live_match: $live, recent_events: $recent, upcoming: $upcoming, _bookkeeping: $bk}')"
ft_write_state "$state"
