// Pure formatting helpers for the football-tracker bar widget/popup.
// No API calls, no state — just turns state.json fields into display strings.

// Wrap a value for safe use as a single POSIX shell argument. bar.shellQuote
// is documented but not actually present on the running bar object at
// runtime, so this plugin does its own quoting rather than depending on it.
function shQuote(value) {
  return "'" + String(value).split("'").join("'\\''") + "'"
}

function safeParse(text) {
  try {
    var parsed = JSON.parse(text)
    return parsed && typeof parsed === "object" ? parsed : {}
  } catch (e) {
    return {}
  }
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function kickoffClock(iso) {
  if (!iso) return ""
  var d = new Date(iso)
  if (isNaN(d.getTime())) return ""
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function minutesUntil(iso) {
  if (!iso) return null
  var d = new Date(iso)
  if (isNaN(d.getTime())) return null
  return Math.round((d.getTime() - Date.now()) / 60000)
}

var WEEKDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function isSameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

// "" for today, "Tomorrow " for tomorrow, else a weekday name — always with a
// trailing space so callers can prefix kickoffClock() directly.
function dayLabel(iso) {
  if (!iso) return ""
  var d = new Date(iso)
  if (isNaN(d.getTime())) return ""
  var now = new Date()
  if (isSameDay(d, now)) return ""
  var tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
  if (isSameDay(d, tomorrow)) return "Tomorrow "
  return WEEKDAY_NAMES[d.getDay()] + " "
}

// Compact label for the bar itself.
function barLabel(state) {
  if (state.live_match) {
    var lm = state.live_match
    return lm.team + " " + lm.team_score + "-" + lm.opponent_score + " " + (lm.elapsed || 0) + "'"
  }
  if (state.next_match) {
    var mins = minutesUntil(state.next_match.kickoff)
    if (mins !== null && mins >= 0 && mins <= 15) return "Kickoff " + kickoffClock(state.next_match.kickoff)
    return state.next_match.team + " " + dayLabel(state.next_match.kickoff) + kickoffClock(state.next_match.kickoff)
  }
  return ""
}

// FotMob has no public API mapping an API-Football fixture id to one of
// its own match pages, so this links to a Google search for the match
// instead of a direct FotMob URL — one extra click, but it never breaks.
function fotmobSearchLink(team, opponent) {
  if (!team || !opponent) return ""
  return "https://www.google.com/search?q=" + encodeURIComponent(team + " vs " + opponent + " fotmob")
}

function eventHeadline(ev) {
  switch (ev.type) {
    case "Goal": return (ev.detail && ev.detail.indexOf("Own") >= 0) ? "Own goal" : "Goal"
    case "Card": return ev.detail || "Card"
    case "subst": return "Substitution"
    default: return ev.type || "Event"
  }
}
