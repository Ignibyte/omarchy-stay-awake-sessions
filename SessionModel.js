.pragma library

// Pure session logic, kept out of Service.qml so it can be reasoned about (and
// exercised) without a running shell. Nothing here touches Qt or the shell.

// `screen` is deliberately absent from `all`: `idle` already stops the
// screensaver by holding the Stay Awake flag, so folding it in would raise the
// screensaver timeout in shell.json for no gain.
var LEVERS = { idle: ["idle", "all"], sleep: ["sleep", "all"], screen: ["screen"] }
var KINDS = ["timed", "process", "command", "manual"]

function clampInt(value, min, max, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.round(n)
  return n < min ? min : (n > max ? max : n)
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// "90" and "90m" are minutes, "2h", "1h30m", "45s", "1h30m10s" all work.
function parseDurationMs(text) {
  var s = String(text || "").trim().toLowerCase()
  if (s === "") return 0
  if (/^\d+$/.test(s)) return parseInt(s, 10) * 60000
  var pattern = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/
  var match = s.match(pattern)
  if (!match || (!match[1] && !match[2] && !match[3])) return 0
  var hours = parseInt(match[1] || "0", 10)
  var minutes = parseInt(match[2] || "0", 10)
  var seconds = parseInt(match[3] || "0", 10)
  return ((hours * 3600) + (minutes * 60) + seconds) * 1000
}

// "17:00" means the next 17:00, today if it has not passed yet.
function parseClockMs(text, nowMs) {
  var match = String(text || "").trim().match(/^(\d{1,2}):(\d{2})$/)
  if (!match) return 0
  var hours = parseInt(match[1], 10)
  var minutes = parseInt(match[2], 10)
  if (hours > 23 || minutes > 59) return 0
  var target = new Date(nowMs)
  target.setHours(hours, minutes, 0, 0)
  var at = target.getTime()
  if (at <= nowMs) at += 86400000
  return at
}

function formatClock(atMs) {
  var when = new Date(atMs)
  return pad2(when.getHours()) + ":" + pad2(when.getMinutes())
}

// Compact enough for a bar slot, and stable: it never flickers between two
// widths on a one-second tick.
function formatRemaining(ms) {
  var total = Math.max(0, Math.round(ms / 1000))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (hours > 0) return hours + "h " + pad2(minutes) + "m"
  if (minutes > 0) return minutes + "m"
  return total + "s"
}

function formatElapsed(ms) {
  var total = Math.max(0, Math.round(ms / 1000))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (hours > 0) return hours + "h " + pad2(minutes) + "m"
  if (minutes > 0) return minutes + "m"
  return total + "s"
}

function normalizeScope(value, fallback) {
  var s = String(value || "").trim().toLowerCase()
  if (s === "idle" || s === "sleep" || s === "all" || s === "screen") return s
  return fallback || "idle"
}

function scopeLabel(scope) {
  if (scope === "sleep") return "suspend"
  if (scope === "all") return "lock and suspend"
  if (scope === "screen") return "the screensaver"
  return "lock"
}

// The screensaver is suppressed by pushing idle.screensaver past idle.lock, so
// the sentinel has to clear the lock as well as any plausible user value.
function screensaverSentinel(lockSeconds) {
  var lock = Number(lockSeconds)
  if (!isFinite(lock) || lock < 0) lock = 0
  return Math.max(86400, Math.round(lock) + 3600)
}

var SCREENSAVER_SENTINEL_FLOOR = 86400
var SCREENSAVER_DEFAULT = 150

// Never take our own sentinel for the user's setting: doing so would record the
// suppression as the value to restore, and each restart would bake it in deeper.
function realScreensaverSeconds(current, remembered) {
  var value = Number(current)
  if (isFinite(value) && value > 0 && value < SCREENSAVER_SENTINEL_FLOOR) return Math.round(value)
  var fallback = Number(remembered)
  if (isFinite(fallback) && fallback > 0 && fallback < SCREENSAVER_SENTINEL_FLOOR) return Math.round(fallback)
  return SCREENSAVER_DEFAULT
}

// A spec is either JSON or a run of key=value pairs, so the same entry point
// serves the CLI, the popup and a hand-typed IPC call.
function parseSpec(text) {
  var raw = String(text || "").trim()
  if (raw === "") return {}
  if (raw.charAt(0) === "{") {
    try {
      var parsed = JSON.parse(raw)
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch (error) {
      return { error: "spec is not valid JSON: " + error }
    }
  }

  var spec = {}
  var pattern = /([a-zA-Z-]+)=("([^"]*)"|'([^']*)'|[^\s]*)/g
  var match
  while ((match = pattern.exec(raw)) !== null) {
    var value = match[3] !== undefined ? match[3] : (match[4] !== undefined ? match[4] : match[2])
    spec[match[1].toLowerCase()] = value
  }
  return spec
}

function specValue(spec, names) {
  for (var i = 0; i < names.length; i++) {
    var value = spec[names[i]]
    if (value !== undefined && value !== null && String(value) !== "") return String(value)
  }
  return ""
}

// Turns a spec into a session, or into { error } naming what was wrong with it.
function buildSession(spec, defaults, nowMs, id) {
  if (spec.error) return { error: spec.error }

  var scope = normalizeScope(specValue(spec, ["scope"]), defaults.scope)
  var label = specValue(spec, ["label", "why", "reason"])
  var grace = specValue(spec, ["grace"])
  var session = {
    id: String(id),
    scope: scope,
    startedAt: nowMs,
    lastTrueAt: nowMs,
    expiresAt: 0,
    pattern: "",
    command: "",
    graceSeconds: grace === "" ? defaults.graceSeconds : clampInt(grace, 0, 600, defaults.graceSeconds)
  }

  var forText = specValue(spec, ["for", "duration"])
  var untilText = specValue(spec, ["until", "till"])
  var processText = specValue(spec, ["while-process", "process", "whileprocess"])
  var commandText = specValue(spec, ["while-command", "command", "whilecommand"])

  if (forText !== "") {
    var duration = parseDurationMs(forText)
    if (duration <= 0) return { error: "could not read a duration from '" + forText + "'" }
    session.kind = "timed"
    session.expiresAt = nowMs + duration
    session.label = label || "For " + formatRemaining(duration)
    return session
  }

  if (untilText !== "") {
    var at = parseClockMs(untilText, nowMs)
    if (at <= 0) return { error: "could not read a time from '" + untilText + "' (expected HH:MM)" }
    session.kind = "timed"
    session.expiresAt = at
    session.label = label || "Until " + formatClock(at)
    return session
  }

  if (processText !== "") {
    session.kind = "process"
    session.pattern = processText
    session.label = label || processText
    return session
  }

  if (commandText !== "") {
    session.kind = "command"
    session.command = commandText
    session.label = label || "Condition"
    return session
  }

  session.kind = "manual"
  session.label = label || "Until you stop it"
  return session
}

function describe(session) {
  if (!session) return ""
  if (session.kind === "timed") return "until " + formatClock(session.expiresAt)
  if (session.kind === "process") return "while " + session.pattern + " is running"
  if (session.kind === "command") return "while the condition holds"
  return "until you stop it"
}

function isWatched(session) {
  return session && (session.kind === "process" || session.kind === "command")
}

function watched(sessions) {
  var out = []
  for (var i = 0; i < sessions.length; i++) if (isWatched(sessions[i])) out.push(sessions[i])
  return out
}

// id, kind and payload, one session per line. The service base64-encodes this
// before handing it to the evaluator, so no user pattern ever appears in a
// command line that pgrep could then match against itself.
function predicateTable(sessions) {
  var lines = []
  for (var i = 0; i < sessions.length; i++) {
    var session = sessions[i]
    var payload = session.kind === "process" ? session.pattern : session.command
    lines.push(session.id + "\t" + session.kind + "\t" + String(payload).replace(/[\r\n]+/g, " "))
  }
  return lines.join("\n") + "\n"
}

function expiredIds(sessions, nowMs) {
  var out = []
  for (var i = 0; i < sessions.length; i++) {
    var session = sessions[i]
    if (session.kind === "timed" && session.expiresAt > 0 && nowMs >= session.expiresAt) out.push(session.id)
  }
  return out
}

function holdsLever(session, lever) {
  var scopes = LEVERS[lever]
  return !!session && !!scopes && scopes.indexOf(session.scope) !== -1
}

function anyHolds(sessions, lever) {
  for (var i = 0; i < sessions.length; i++) if (holdsLever(sessions[i], lever)) return true
  return false
}

function remainingMs(session, nowMs) {
  if (!session || session.kind !== "timed" || session.expiresAt <= 0) return -1
  return Math.max(0, session.expiresAt - nowMs)
}

// The soonest deadline across every timed session, or -1 when none has one.
function soonestRemainingMs(sessions, nowMs) {
  var soonest = -1
  for (var i = 0; i < sessions.length; i++) {
    var remaining = remainingMs(sessions[i], nowMs)
    if (remaining < 0) continue
    if (soonest < 0 || remaining < soonest) soonest = remaining
  }
  return soonest
}

// One session shows what it is; several show how many, with the next deadline
// when there is one, because that is the number worth watching.
function barLabel(sessions, nowMs) {
  if (sessions.length === 0) return ""
  if (sessions.length === 1) {
    var only = sessions[0]
    var remaining = remainingMs(only, nowMs)
    if (remaining >= 0) return formatRemaining(remaining)
    return shortLabel(only.label)
  }
  var soonest = soonestRemainingMs(sessions, nowMs)
  if (soonest >= 0) return sessions.length + "× " + formatRemaining(soonest)
  return sessions.length + "×"
}

function shortLabel(text) {
  var s = String(text || "").trim()
  return s.length > 14 ? s.slice(0, 13) + "…" : s
}

function tooltip(sessions, nowMs) {
  if (sessions.length === 0) return "Stay Awake — nothing is holding the screen"
  var lines = []
  for (var i = 0; i < sessions.length; i++) {
    var session = sessions[i]
    var remaining = remainingMs(session, nowMs)
    var tail = remaining >= 0 ? formatRemaining(remaining) + " left" : describe(session)
    lines.push(session.label + " — " + tail)
  }
  return lines.join("\n")
}

// A plugin that is both a service and a bar widget has one entry in
// shell.json, and it can be in either place. Read whichever exists.
function settingsFor(shellConfig, pluginId) {
  var id = String(pluginId || "")
  if (!shellConfig || typeof shellConfig !== "object") return {}

  var bar = shellConfig.bar
  if (bar && typeof bar === "object" && bar.layout && typeof bar.layout === "object") {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = bar.layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && String(entries[i].id) === id) return entries[i]
      }
    }
  }

  if (Array.isArray(shellConfig.plugins)) {
    for (var p = 0; p < shellConfig.plugins.length; p++) {
      if (shellConfig.plugins[p] && String(shellConfig.plugins[p].id) === id) return shellConfig.plugins[p]
    }
  }

  return {}
}

function publicSession(session, nowMs) {
  return {
    id: session.id,
    kind: session.kind,
    label: session.label,
    scope: session.scope,
    holds: scopeLabel(session.scope),
    describes: describe(session),
    startedAt: session.startedAt,
    heldForMs: Math.max(0, nowMs - session.startedAt),
    remainingMs: remainingMs(session, nowMs),
    pattern: session.pattern,
    command: session.command,
    graceSeconds: session.graceSeconds
  }
}

function publicSessions(sessions, nowMs) {
  var out = []
  for (var i = 0; i < sessions.length; i++) out.push(publicSession(sessions[i], nowMs))
  return out
}
