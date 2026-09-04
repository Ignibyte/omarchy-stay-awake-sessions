import QtQuick
import Quickshell
import Quickshell.Io
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

  property var sessions: []
  property int nextSessionId: 1
  property double nowMs: Date.now()

  readonly property bool holding: sessions.length > 0
  readonly property bool wantIdleHold: SessionModel.anyHolds(sessions, "idle")
  readonly property bool wantSleepHold: SessionModel.anyHolds(sessions, "sleep")

  property bool holdingIdle: false
  property bool userStayAwake: false
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

  function syncIdleHold() {
    var idle = root.idleService
    if (!idle) return

    if (root.wantIdleHold && !root.holdingIdle) {
      root.userStayAwake = idle.stayAwake === true
      root.holdingIdle = true
      root.applyingIdleHold = true
      idle.setIdleEnabled(false)
      root.applyingIdleHold = false
      root.persistHold(true)
    } else if (!root.wantIdleHold && root.holdingIdle) {
      root.holdingIdle = false
      root.applyingIdleHold = true
      idle.setIdleEnabled(!root.userStayAwake)
      root.applyingIdleHold = false
      root.persistHold(false)
    }
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

  // `held` rather than `holding`: a parameter that shadows a property of the
  // same name on this object is a trap QML will not warn about.
  function persistHold(held) {
    var payload = JSON.stringify({
      holding: !!held,
      restoreTo: !!root.userStayAwake,
      shellPid: Quickshell.processId
    })
    // argv rather than an interpolated command line: the payload never has to
    // survive a round of shell quoting, and the directory is made on the way.
    stateWriter.command = ["bash", "-c",
      'mkdir -p "$1" && printf "%s\\n" "$2" > "$1/hold"',
      "stay-awake-sessions", root.stateDir, payload]
    stateWriter.running = true
  }

  // Recovery is deliberately one-directional: it only ever puts the flag back
  // the way it was, and only when the shell that took it is gone. A live shell
  // pid means this is an ordinary plugin reload, where Component.onDestruction
  // has already released the hold.
  function tryRecover() {
    if (!root.pendingRecovery || !root.idleService) return

    var saved = root.pendingRecovery
    root.pendingRecovery = null
    if (saved.holding !== true) return
    if (Number(saved.shellPid) === Quickshell.processId) return

    root.log("releasing an idle hold left behind by a shell that is gone")
    root.applyingIdleHold = true
    root.idleService.setIdleEnabled(!saved.restoreTo)
    root.applyingIdleHold = false
    root.persistHold(false)
  }

  Process {
    id: stateWriter
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.log("state write: " + text)
    }
    onExited: function(exitCode) { if (exitCode !== 0) root.log("state write failed, exit " + exitCode) }
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

  // ----------------------------------------------------------- the conditions

  // Deadlines ride the one-second clock rather than the condition poll, so a
  // timed hold ends within a second of its time however slow the poll is set.
  function expireDue() {
    root.nowMs = Date.now()
    var expired = SessionModel.expiredIds(sessions, root.nowMs)
    if (expired.length > 0) endMany(expired, "the time was up")
  }

  function checkConditions() {
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
  }

  Component.onDestruction: {
    // Leaving the flag held after the plugin is disabled would strand the
    // machine awake with nothing left to release it.
    if (root.holdingIdle && root.idleService) {
      root.applyingIdleHold = true
      root.idleService.setIdleEnabled(!root.userStayAwake)
      root.applyingIdleHold = false
    }
    if (sleepInhibitor.running) sleepInhibitor.running = false
  }
}
