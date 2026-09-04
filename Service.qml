import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "SessionModel.js" as SessionModel

// The session engine. Holds a list of reasons the machine should stay awake,
// each with a condition that decides when it is over, and drives two levers
// while at least one of them is live:
//
//   idle  — the first-party omarchy.idle service, called in process, which is
//           the same flag the stock Stay Awake indicator toggles.
//   sleep — a systemd-inhibit child holding an idle:sleep block for as long as
//           it runs.
//
// Both are released when the last session ends, and the idle flag is restored
// to whatever the user had set before the first session took it.
Item {
  id: root

  // Injected by the shell's service loader after the object is constructed,
  // so nothing here may read `shell` from Component.onCompleted.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "ignibyte.stay-awake-sessions"
  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string evaluatorPath: sourceDir === "" ? "" : sourceDir + "/bin/eval-predicates"

  readonly property var idleService: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("omarchy.idle") : null

  readonly property var config: shell && shell.shellConfig
    ? SessionModel.settingsFor(shell.shellConfig, pluginId) : ({})
  readonly property int defaultMinutes: SessionModel.clampInt(config.defaultMinutes, 1, 1440, 60)
  readonly property string defaultScope: SessionModel.normalizeScope(config.defaultScope, "idle")
  readonly property int pollSeconds: SessionModel.clampInt(config.pollSeconds, 1, 300, 5)
  readonly property int graceSeconds: SessionModel.clampInt(config.graceSeconds, 0, 600, 15)
  readonly property bool notifyOnEnd: config.notify !== false
  readonly property bool notifyOnStart: config.notifyOnStart === true
  readonly property var quickMinutes: SessionModel.parseNumberList(config.quickMinutes, [5, 15, 30], 1, 1440, 6)
  readonly property var quickHours: SessionModel.parseNumberList(config.quickHours, [1, 2, 4], 1, 24, 6)

  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle
    ? shell.shellConfig.idle : ({})
  readonly property int lockSeconds: SessionModel.clampInt(idleConfig.lock, 1, 86400, 300)
  readonly property int configuredScreensaverSeconds: SessionModel.clampInt(idleConfig.screensaver, 1, 604800, 150)
  readonly property int screensaverSentinel: SessionModel.screensaverSentinel(lockSeconds)

  property var sessions: []
  property int nextSessionId: 1
  property double nowMs: Date.now()

  readonly property bool holding: sessions.length > 0
  readonly property bool wantIdleHold: SessionModel.anyHolds(sessions, "idle")
  readonly property bool wantSleepHold: SessionModel.anyHolds(sessions, "sleep")
  readonly property bool wantScreensaverOff: standingScreensaverOff || SessionModel.anyHolds(sessions, "screen")

  property bool holdingIdle: false
  property bool userStayAwake: false

  // The screensaver lever. Omarchy's Stay Awake flag stops the screensaver and
  // the lock together, but the two timeouts are separate numbers in shell.json:
  // pushing idle.screensaver past idle.lock stops the screensaver on its own and
  // leaves the lock firing. `standingScreensaverOff` is the preference switch;
  // a session with `scope: screen` holds the same lever for its own lifetime.
  property bool standingScreensaverOff: false
  property bool suppressingScreensaver: false
  property int savedScreensaverSeconds: 0
  // Set around our own writes to the idle flag so the change we just made is
  // not read back as the user overriding us.
  property bool applyingIdleHold: false

  property var notifyQueue: []

  // A crash-recovery breadcrumb. The shell can die (or be restarted) while
  // sessions hold the idle flag, and the flag outlives the process that took
  // it — leaving a machine that never sleeps and no session left to say why.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/stay-awake-sessions"
  readonly property string statePath: stateDir + "/hold"
  property var pendingRecovery: null
  property string pendingStatePayload: ""
  property bool hasPendingStatePayload: false


  // ------------------------------------------------------------- sessions

  function defaults() {
    return { scope: root.defaultScope, graceSeconds: root.graceSeconds }
  }

  function findIndex(id) {
    var key = String(id)
    for (var i = 0; i < sessions.length; i++) if (sessions[i].id === key) return i
    return -1
  }

  function start(spec) {
    var parsed = SessionModel.parseSpec(spec)
    var session = SessionModel.buildSession(parsed, defaults(), Date.now(), root.nextSessionId)
    if (session.error) return "error: " + session.error

    root.nextSessionId += 1
    var next = sessions.slice()
    next.push(session)
    sessions = next
    log("hold " + session.id + " " + session.label + " (" + SessionModel.describe(session)
      + ", blocks " + SessionModel.scopeLabel(session.scope) + ")")
    if (root.notifyOnStart)
      notify(session.label + " — holding", "Blocks " + SessionModel.scopeLabel(session.scope)
        + " " + SessionModel.describe(session) + ".")
    // A condition may already be false at this moment (the process has not
    // started yet); the grace period covers that, so nothing is checked here.
    return session.id
  }

  function endOne(id, reason) {
    var index = findIndex(id)
    if (index === -1) return "unknown"
    var session = sessions[index]
    var next = sessions.slice()
    next.splice(index, 1)
    sessions = next
    finish([session], reason)
    return "ended"
  }

  function endMany(ids, reason) {
    if (ids.length === 0) return
    var removed = []
    var next = []
    for (var i = 0; i < sessions.length; i++) {
      if (ids.indexOf(sessions[i].id) === -1) next.push(sessions[i])
      else removed.push(sessions[i])
    }
    sessions = next
    finish(removed, reason)
  }

  function endAll(reason) {
    if (sessions.length === 0) return "none"
    var removed = sessions.slice()
    sessions = []
    finish(removed, reason)
    return "ended " + removed.length
  }

  function finish(removed, reason) {
    for (var i = 0; i < removed.length; i++) {
      var session = removed[i]
      log("release " + session.id + " " + session.label + " — " + reason)
      if (root.notifyOnEnd)
        notify(session.label + " — hold ended",
          reason + ". Held for " + SessionModel.formatElapsed(Date.now() - session.startedAt) + ".")
    }
  }

  function toggle() {
    if (sessions.length > 0) return endAll("switched off")
    return start("for=" + root.defaultMinutes + "m")
  }

  // -------------------------------------------------------------- the levers

  onWantIdleHoldChanged: syncIdleHold()
  onWantSleepHoldChanged: syncSleepHold()
  onWantScreensaverOffChanged: syncScreensaverHold()

  function syncIdleHold() {
    var idle = root.idleService
    if (!idle) return

    // Settle a leftover hold first, so the flag this reads as the user's own
    // setting is not one a dead shell left switched on.
    if (root.pendingRecovery) tryRecover()

    if (root.wantIdleHold && !root.holdingIdle) {
      root.userStayAwake = idle.stayAwake === true
      root.holdingIdle = true
      root.applyingIdleHold = true
      idle.setIdleEnabled(false)
      root.applyingIdleHold = false
      root.persistState()
    } else if (!root.wantIdleHold && root.holdingIdle) {
      root.holdingIdle = false
      root.applyingIdleHold = true
      idle.setIdleEnabled(!root.userStayAwake)
      root.applyingIdleHold = false
      root.persistState()
    }
  }

  // Written through the shell's own mutator so the edit lands on the config the
  // shell currently holds, rather than racing whatever else is writing the file.
  function writeScreensaverSeconds(value) {
    if (!shell || typeof shell.mutateShellConfig !== "function") return false
    shell.mutateShellConfig(function(copy) {
      if (!copy.idle || typeof copy.idle !== "object") copy.idle = {}
      copy.idle.screensaver = value
    })
    return true
  }

  function syncScreensaverHold() {
    if (!shell || typeof shell.mutateShellConfig !== "function") return

    if (root.wantScreensaverOff && !root.suppressingScreensaver) {
      root.savedScreensaverSeconds = SessionModel.realScreensaverSeconds(
        root.configuredScreensaverSeconds, root.savedScreensaverSeconds)
      root.suppressingScreensaver = true
      root.writeScreensaverSeconds(root.screensaverSentinel)
      root.log("screensaver off (was " + root.savedScreensaverSeconds + "s)")
      root.persistState()
    } else if (!root.wantScreensaverOff && root.suppressingScreensaver) {
      var restored = SessionModel.realScreensaverSeconds(0, root.savedScreensaverSeconds)
      root.suppressingScreensaver = false
      root.writeScreensaverSeconds(restored)
      root.log("screensaver back on at " + restored + "s")
      root.persistState()
    }
  }

  function setScreensaverOff(off) {
    root.standingScreensaverOff = !!off
    // A standing switch outlives the shell, so record which kind of suppression
    // this is even when a session already had the lever held.
    root.persistState()
    return root.standingScreensaverOff ? "off" : "on"
  }

  function syncSleepHold() {
    if (root.wantSleepHold) {
      if (sleepInhibitor.running) return
      sleepInhibitor.command = [
        "systemd-inhibit",
        "--what=idle:sleep",
        "--mode=block",
        "--who=Stay Awake Sessions",
        "--why=A stay-awake session is holding this machine",
        "sleep", "infinity"
      ]
      sleepInhibitor.running = true
    } else if (sleepInhibitor.running) {
      sleepInhibitor.running = false
    }
  }

  // Turning the stock Stay Awake indicator off while sessions hold it is a
  // clear instruction: the user wants the machine to sleep again, so the
  // sessions go with it rather than silently switching the flag back on.
  Connections {
    target: root.idleService
    ignoreUnknownSignals: true
    function onStayAwakeChanged() {
      if (root.applyingIdleHold) return
      if (!root.holdingIdle) return
      if (root.idleService && root.idleService.stayAwake === false) {
        root.userStayAwake = false
        root.endAll("Stay Awake was switched off")
      }
    }
  }

  // No parameters on purpose: a parameter that shadows a property of the same
  // name on this object silently resolves to the property, and QML gives no
  // warning. Reading the state straight off `root` cannot go wrong that way.
  function persistState() {
    var payload = JSON.stringify({
      holding: !!root.holdingIdle,
      restoreTo: !!root.userStayAwake,
      shellPid: Quickshell.processId,
      screensaver: {
        suppressed: !!root.suppressingScreensaver,
        mode: root.standingScreensaverOff ? "standing" : "session",
        original: root.savedScreensaverSeconds
      }
    })
    // Setting `running` on a Process that is already running does nothing, and
    // the replaced command is simply lost — so two state changes in quick
    // succession would leave the breadcrumb holding whichever one happened to
    // win, which is how a session-scoped suppression came back as a standing
    // one. Queue instead, and let the last write stand.
    if (stateWriter.running) {
      root.pendingStatePayload = payload
      root.hasPendingStatePayload = true
      return
    }
    root.writeState(payload)
  }

  function writeState(payload) {
    // argv rather than an interpolated command line: the payload never has to
    // survive a round of shell quoting, and the directory is made on the way.
    stateWriter.command = ["bash", "-c",
      'mkdir -p "$1" && printf "%s\\n" "$2" > "$1/hold"',
      "stay-awake-sessions", root.stateDir, payload]
    stateWriter.running = true
  }

  // Recovery only ever releases, never re-enables. After a crash there is no
  // way to tell a flag the user set by hand from one our own dead hold left
  // behind — and acting on the breadcrumb's recorded prior value poisons the
  // chain, because the next hold then records the leak as the user's setting.
  // A machine that never sleeps is the worse of the two mistakes.
  //
  // A live shell pid means this is an ordinary plugin reload, where
  // Component.onDestruction has already released the hold.
  function tryRecover() {
    if (!root.pendingRecovery || !root.idleService) return

    var saved = root.pendingRecovery
    root.pendingRecovery = null
    var deadShell = Number(saved.shellPid) !== Quickshell.processId

    recoverScreensaver(saved.screensaver)

    if (saved.holding !== true) return
    if (!deadShell) return
    if (root.holdingIdle) return

    root.log("releasing an idle hold left behind by a shell that is gone")
    root.applyingIdleHold = true
    root.idleService.setIdleEnabled(true)
    root.applyingIdleHold = false
    root.persistState()
  }

  // The screensaver splits from the idle flag here. A standing switch is a
  // preference and is meant to outlive the shell, so it is adopted rather than
  // undone — the plugin picks the lever back up and keeps owning it. A
  // session-scoped suppression had a lifetime that died with the shell, so its
  // timeout goes back, or the user's screensaver stays silently dead in
  // shell.json with nothing left to explain it.
  function recoverScreensaver(saver) {
    if (!saver || saver.suppressed !== true) return
    var original = SessionModel.realScreensaverSeconds(0, saver.original)

    if (String(saver.mode) === "standing") {
      root.savedScreensaverSeconds = original
      root.suppressingScreensaver = true
      root.standingScreensaverOff = true
      return
    }

    // Session-scoped, and this instance has no sessions: whether the shell died
    // or the plugin merely reloaded, whatever justified the suppression is gone.
    // Writing the original back is idempotent, so doing it in both cases costs
    // nothing and closes the reload leak.
    root.log("restoring the screensaver timeout left raised with no session behind it")
    root.savedScreensaverSeconds = original
    root.suppressingScreensaver = false
    root.writeScreensaverSeconds(original)
    root.persistState()
  }

  Process {
    id: stateWriter
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.log("state write: " + text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.log("state write failed, exit " + exitCode)
      if (!root.hasPendingStatePayload) return
      var payload = root.pendingStatePayload
      root.hasPendingStatePayload = false
      root.pendingStatePayload = ""
      root.writeState(payload)
    }
  }

  FileView {
    id: holdState
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        root.pendingRecovery = JSON.parse(text())
      } catch (error) {
        root.pendingRecovery = null
      }
      root.tryRecover()
    }
  }

  onIdleServiceChanged: {
    tryRecover()
    syncIdleHold()
  }

  Process {
    id: sleepInhibitor
    onExited: function(exitCode, exitStatus) {
      // A sleep inhibitor that dies while sessions still want it (a killed
      // child, systemd-inhibit missing) must not leave them believing the
      // machine is held.
      if (root.wantSleepHold) {
        root.log("sleep inhibitor exited unexpectedly (code " + exitCode + ")")
        Qt.callLater(root.syncSleepHold)
      }
    }
  }

  // ------------------------------------------------------------- open windows

  // The compositor's own toplevel list, which is live and needs no subprocess.
  // Amphetamine's "while this app is running" is this list plus a match.
  function openApps() {
    var out = []
    var seen = ({})
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var top = values[i]
        if (!top) continue
        var appId = String(top.appId || "")
        if (appId === "" || seen[appId]) continue
        seen[appId] = true
        out.push({ appId: appId, title: String(top.title || "") })
      }
    } catch (error) {
      root.log("could not read the window list: " + error)
    }
    out.sort(function(left, right) { return left.appId.localeCompare(right.appId) })
    return out
  }

  function appIsOpen(pattern) {
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var top = values[i]
        if (top && SessionModel.matchesApp(top.appId, top.title, pattern)) return true
      }
    } catch (error) {
      // A compositor without the toplevel protocol: hold rather than drop it.
      return true
    }
    return false
  }

  // A window closing should end its hold promptly, not at the next poll.
  Connections {
    target: ToplevelManager.toplevels
    ignoreUnknownSignals: true
    function onValuesChanged() { if (root.holding) Qt.callLater(root.checkConditions) }
  }

  // ----------------------------------------------------------- the conditions

  // Deadlines ride the one-second clock rather than the condition poll, so a
  // timed hold ends within a second of its time however slow the poll is set.
  function expireDue() {
    root.nowMs = Date.now()
    var expired = SessionModel.expiredIds(sessions, root.nowMs)
    if (expired.length > 0) endMany(expired, "the time was up")
  }

  function checkConditions() {
    // App conditions are answered here and now, from the toplevel list.
    var appResults = ({})
    var sawApp = false
    for (var i = 0; i < sessions.length; i++) {
      var session = sessions[i]
      if (session.kind !== "app") continue
      sawApp = true
      appResults[session.id] = root.appIsOpen(session.app)
    }
    if (sawApp) applyResults(appResults)

    var pending = SessionModel.watched(sessions)
    if (pending.length === 0) return
    if (evaluator.running) return
    if (root.evaluatorPath === "") return

    evaluator.results = ({})
    evaluator.command = ["bash", root.evaluatorPath, Qt.btoa(SessionModel.predicateTable(pending))]
    evaluator.running = true
  }

  function applyResults(results) {
    var now = Date.now()
    var dead = []
    var next = sessions.slice()

    for (var i = 0; i < next.length; i++) {
      var session = next[i]
      if (!SessionModel.isWatched(session)) continue
      // A pass that answered for some sessions says nothing about the others.
      if (results[session.id] === undefined) continue
      if (results[session.id] === true) {
        session.lastTrueAt = now
        continue
      }
      if (now - session.lastTrueAt > session.graceSeconds * 1000) dead.push(session.id)
    }

    if (dead.length > 0) endMany(dead, "the condition ended")
  }

  Process {
    id: evaluator
    property var results: ({})
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line).split("\t")
        if (parts.length >= 2) evaluator.results[parts[0]] = parts[1].trim() === "1"
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.log("condition check failed (exit " + exitCode + ")")
        return
      }
      root.applyResults(evaluator.results)
    }
  }

  Timer {
    id: conditionTimer
    interval: root.pollSeconds * 1000
    repeat: true
    running: root.holding
    onTriggered: root.checkConditions()
  }

  // Drives the countdown in the bar and retires sessions the moment they are
  // due. Separate from the condition poll so a long poll interval neither
  // makes the clock stutter nor delays a deadline.
  Timer {
    id: clockTimer
    interval: 1000
    repeat: true
    running: root.holding
    onTriggered: root.expireDue()
  }

  // ------------------------------------------------------------------ output

  function log(message) {
    console.log("stay-awake-sessions " + new Date().toISOString() + " " + message)
  }

  function notify(title, body) {
    var queue = notifyQueue.slice()
    queue.push([title, body])
    notifyQueue = queue
    drainNotifications()
  }

  function drainNotifications() {
    if (notifier.running || notifyQueue.length === 0) return
    var queue = notifyQueue.slice()
    var item = queue.shift()
    notifyQueue = queue
    notifier.command = ["notify-send", "-a", "Stay Awake", "-i", "preferences-desktop-screensaver", item[0], item[1]]
    notifier.running = true
  }

  Process {
    id: notifier
    onExited: Qt.callLater(root.drainNotifications)
  }

  function statusJson() {
    var now = Date.now()
    return JSON.stringify({
      holding: root.holding,
      count: root.sessions.length,
      blocksIdle: root.wantIdleHold,
      blocksSleep: root.wantSleepHold,
      screensaverOff: root.wantScreensaverOff,
      screensaverSwitch: root.standingScreensaverOff ? "off" : "on",
      screensaverSeconds: root.suppressingScreensaver
        ? root.savedScreensaverSeconds : root.configuredScreensaverSeconds,
      lockSeconds: root.lockSeconds,
      sleepInhibitorRunning: sleepInhibitor.running,
      idleServiceReachable: !!root.idleService,
      stayAwake: root.idleService ? root.idleService.stayAwake : null,
      restoreStayAwakeTo: root.holdingIdle ? root.userStayAwake : null,
      nextDeadlineMs: SessionModel.soonestRemainingMs(root.sessions, now),
      barLabel: SessionModel.barLabel(root.sessions, now),
      pollSeconds: root.pollSeconds,
      graceSeconds: root.graceSeconds,
      defaultMinutes: root.defaultMinutes,
      defaultScope: root.defaultScope,
      quickMinutes: root.quickMinutes,
      quickHours: root.quickHours,
      sessions: SessionModel.publicSessions(root.sessions, now)
    })
  }

  IpcHandler {
    target: "stayawake"

    // Start a hold. The spec is either JSON or key=value pairs:
    //   for=90m  until=17:00  while-process=cargo  while-command='...'
    //   label='Gate run'  scope=idle|sleep|all  grace=30
    function hold(spec: string): string {
      return root.start(spec)
    }

    function end(id: string): string {
      return root.endOne(id, "ended from the command line")
    }

    function endAll(): string {
      return root.endAll("ended from the command line")
    }

    function toggle(): string {
      return root.toggle()
    }

    function status(): string {
      return root.statusJson()
    }

    function list(): string {
      return JSON.stringify(SessionModel.publicSessions(root.sessions, Date.now()))
    }

    // The open windows, for a picker that offers what is actually running.
    function apps(): string {
      return JSON.stringify(root.openApps())
    }

    // The standing screensaver switch, separate from any session: "off", "on",
    // "toggle", or anything else to read it back.
    function screensaver(action: string): string {
      var wanted = String(action || "").trim().toLowerCase()
      if (wanted === "off") return root.setScreensaverOff(true)
      if (wanted === "on") return root.setScreensaverOff(false)
      if (wanted === "toggle") return root.setScreensaverOff(!root.standingScreensaverOff)
      return root.standingScreensaverOff ? "off" : "on"
    }
  }

  Component.onDestruction: {
    // Leaving a lever held after the plugin is disabled would strand the
    // machine awake with nothing left to release it.
    if (root.holdingIdle && root.idleService) {
      root.applyingIdleHold = true
      root.idleService.setIdleEnabled(!root.userStayAwake)
      root.applyingIdleHold = false
    }
    // A standing switch is a preference and stays; a session's suppression goes.
    if (root.suppressingScreensaver && !root.standingScreensaverOff) {
      root.writeScreensaverSeconds(SessionModel.realScreensaverSeconds(0, root.savedScreensaverSeconds))
    }
    if (sleepInhibitor.running) sleepInhibitor.running = false
  }
}
