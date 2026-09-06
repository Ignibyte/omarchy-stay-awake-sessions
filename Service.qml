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
  readonly property var quickMinutes: SessionModel.parseNumberList(config.quickMinutes, [5, 15, 30, 45], 1, 1440, 6)
  readonly property var quickHours: SessionModel.parseNumberList(config.quickHours, [1, 2, 4, 8], 1, 24, 6)

  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle
    ? shell.shellConfig.idle : ({})
  readonly property int lockSeconds: SessionModel.clampInt(idleConfig.lock, 1, 86400, 300)
  readonly property int configuredScreensaverSeconds: SessionModel.clampInt(idleConfig.screensaver, 1, 604800, 150)
  readonly property int screensaverSentinel: SessionModel.screensaverSentinel(lockSeconds)

  property var sessions: []
  property int nextSessionId: 1
  property double nowMs: Date.now()
  onSessionsChanged: persistState()

  readonly property bool holding: sessions.length > 0
  readonly property bool wantIdleHold: SessionModel.anyHolds(sessions, "idle")
  readonly property bool wantSleepHold: SessionModel.anyHolds(sessions, "sleep")
  readonly property bool wantScreensaverOff: standingScreensaverOff || SessionModel.anyHolds(sessions, "screen")

  property bool holdingIdle: false
  property bool userStayAwake: false
  // When the idle lever was last taken, and whether the one re-assertion the
  // settle window allows has been spent.
  property double idleHeldAt: 0
  property bool reassertedIdle: false
  readonly property int settleMs: 3000

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
  // The same file carries the sessions themselves, so the next shell can pick
  // the holds back up instead of quietly dropping what the user asked for.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/stay-awake-sessions"
  readonly property string statePath: stateDir + "/hold"
  property var pendingRecovery: null
  property string pendingStatePayload: ""
  property bool hasPendingStatePayload: false
  // Rewritten once a minute while anything is held, so the breadcrumb's age
  // says how long the shell that wrote it has been gone, not how long ago a
  // hold last changed. Without this a hold taken in the morning was judged
  // stale by the first restart after lunch.
  property double lastPersistAt: 0
  readonly property int heartbeatMs: 60000
  // Until recovery has run, the breadcrumb on disk is the last instance's
  // truth and this one must not touch it. A new instance's `sessions` is
  // set during construction, which fires onSessionsChanged and would write
  // an empty breadcrumb before the old one had even been read; an instance
  // unloaded again a moment later (two reloads back to back) would then
  // leave nothing for the next one to rebuild. Set once the breadcrumb has
  // been read and acted on, or found missing.
  property bool recovered: false


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
    if (!idle || !root.idleStateReady) return

    // Settle a leftover hold first, so the flag this reads as the user's own
    // setting is not one a dead shell left switched on. Until recovery has
    // run, nothing is taken: the sessions that want the lever are either the
    // ones about to be rebuilt, or new ones that can wait the same beat.
    if (root.pendingRecovery) { recoveryDelay.restart(); return }

    if (root.wantIdleHold && !root.holdingIdle) {
      root.userStayAwake = idle.stayAwake === true
      root.holdingIdle = true
      root.idleHeldAt = Date.now()
      root.reassertedIdle = false
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
  //
  // One exception. At startup the idle service reads its own flag file through
  // a child process and applies whatever it finds when that lands, even over a
  // hold taken a moment earlier by IPC; the result is a flip to off within a
  // second of the hold, which is not the user. Inside a short settle window
  // the hold is taken again, once, and logged. A second flip, or one later
  // than the window, is the user and is obeyed.
  Connections {
    target: root.idleService
    ignoreUnknownSignals: true
    function onStayAwakeChanged() {
      if (root.applyingIdleHold) return
      if (!root.holdingIdle) return
      if (!root.idleService || root.idleService.stayAwake !== false) return
      if (!root.reassertedIdle && Date.now() - root.idleHeldAt < root.settleMs) {
        root.reassertedIdle = true
        root.log("the idle service loaded its state over a fresh hold; taking the hold again")
        root.applyingIdleHold = true
        root.idleService.setIdleEnabled(false)
        root.applyingIdleHold = false
        return
      }
      root.userStayAwake = false
      root.endAll("Stay Awake was switched off")
    }
  }

  // No parameters on purpose: a parameter that shadows a property of the same
  // name on this object silently resolves to the property, and QML gives no
  // warning. Reading the state straight off `root` cannot go wrong that way.
  function breadcrumbText(sessions, holdingFlag, restoreTo, suppressed) {
    return JSON.stringify({
      holding: holdingFlag,
      restoreTo: restoreTo,
      shellPid: Quickshell.processId,
      savedAt: Date.now(),
      sessions: sessions,
      screensaver: {
        suppressed: suppressed,
        mode: root.standingScreensaverOff ? "standing" : "session",
        original: root.savedScreensaverSeconds
      }
    })
  }

  function persistState() {
    if (!root.recovered) return
    root.lastPersistAt = Date.now()
    var payload = root.breadcrumbText(SessionModel.persistableSessions(root.sessions),
      !!root.holdingIdle, !!root.userStayAwake, !!root.suppressingScreensaver)
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

  function heartbeat() {
    if (root.sessions.length === 0) return
    if (Date.now() - root.lastPersistAt < root.heartbeatMs) return
    root.persistState()
  }

  function writeState(payload) {
    // argv rather than an interpolated command line: the payload never has to
    // survive a round of shell quoting, and the directory is made on the way.
    stateWriter.command = ["bash", "-c",
      'mkdir -p "$1" && printf "%s\\n" "$2" > "$1/hold"',
      "stay-awake-sessions", root.stateDir, payload]
    stateWriter.running = true
  }

  // Recovery of the flag only ever releases, never re-enables. After a crash
  // there is no way to tell a flag the user set by hand from one our own dead
  // hold left behind — and acting on the breadcrumb's recorded prior value
  // poisons the chain, because the next hold then records the leak as the
  // user's setting. A machine that never sleeps is the worse of the two
  // mistakes.
  //
  // The sessions are another matter: the user asked for them, and a shell
  // restart is not the user changing their mind. Once the flag is settled they
  // are rebuilt and take the levers again through the ordinary path, which
  // records the flag as it stands after the release, so nothing leaks.
  //
  // A live shell pid means an ordinary plugin reload. The shell reloads every
  // plugin when any local plugin changes, the first-party idle service among
  // them, so the release made on the way out can vanish under that service's
  // own reload and the flag comes back on from its file. A hold the last
  // instance took is therefore a leak whenever the flag is still on now,
  // dead shell or not; a flag already off needs nothing. On a reload the
  // breadcrumb was written by this very process, so it is fresh by
  // definition and its record of the user's own setting can be trusted.
  // The idle service reads its own flag file asynchronously at startup and
  // applies whatever it finds when the read lands. A hold taken before that
  // moment is overwritten by it, and the flip then reads as the user switching
  // Stay Awake off, which ends every session. So nothing here touches the flag
  // until that service says its state is loaded; a shell without the property
  // reports undefined, which is not false, and proceeds as before.
  readonly property bool idleStateReady: !!idleService && idleService.stayAwakeStateLoaded !== false

  function tryRecover() {
    if (!root.pendingRecovery || !root.idleService || !root.idleStateReady) return

    var saved = root.pendingRecovery
    root.pendingRecovery = null
    root.recovered = true
    var now = Date.now()
    var deadShell = Number(saved.shellPid) !== Quickshell.processId
    var leftHolding = saved.holding === true && !root.holdingIdle
    var priorOn = !deadShell && saved.restoreTo === true
    root.log("recovering after a shell " + (deadShell ? "restart" : "reload") + ": the breadcrumb "
      + (saved.holding === true ? "held" : "did not hold") + " the flag, the flag is "
      + (root.idleService.stayAwake === true ? "on" : "off") + ", "
      + (Array.isArray(saved.sessions) ? saved.sessions.length : 0) + " saved")

    recoverScreensaver(saved.screensaver)

    var restored = SessionModel.restoreSessions(saved.sessions, deadShell ? saved.savedAt : now, now, defaults())
    var keeping = !restored.stale && restored.sessions.length > 0 && root.sessions.length === 0
    var wantsIdle = keeping && SessionModel.anyHolds(restored.sessions, "idle")

    if (leftHolding && wantsIdle) {
      // The holds being kept want the flag on, and a dead shell left it on.
      // Adopt it as this shell's own hold rather than release it and take it
      // straight back: the idle service persists every change through a file
      // it also watches, and two writes a millisecond apart make it read its
      // own file mid-flight and flip the flag under us. The user's setting is
      // taken as off, exactly what a release would have recorded.
      root.log("adopting the idle hold left by the last instance, for the holds being kept")
      root.userStayAwake = priorOn
      root.holdingIdle = true
      root.idleHeldAt = now
      root.reassertedIdle = false
      root.applyingIdleHold = true
      root.idleService.setIdleEnabled(false)
      root.applyingIdleHold = false
      root.persistState()
    } else if (leftHolding) {
      root.log(priorOn ? "giving the idle flag back to the user after the last instance's hold"
        : "releasing an idle hold left behind by the last instance")
      root.applyingIdleHold = true
      root.idleService.setIdleEnabled(!priorOn)
      root.applyingIdleHold = false
      root.persistState()
    }

    if (restored.stale) {
      root.log("not restoring holds from a breadcrumb older than the restore window")
      root.persistState()
      return
    }
    if (restored.expired.length > 0) finish(restored.expired, "the time was up while the shell was away")
    if (!keeping) return
    if (restored.nextId > root.nextSessionId) root.nextSessionId = restored.nextId
    root.sessions = restored.sessions
    root.log("kept " + restored.sessions.length + (restored.sessions.length === 1 ? " hold" : " holds")
      + " across a shell " + (deadShell ? "restart" : "reload") + ": " + SessionModel.sessionLabels(restored.sessions))
    Qt.callLater(root.checkConditions)
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
    blockWrites: true
    printErrors: false
    onLoaded: {
      try {
        root.pendingRecovery = JSON.parse(text())
      } catch (error) {
        root.pendingRecovery = null
      }
      if (!root.pendingRecovery) root.recovered = true
      else if (root.idleStateReady) recoveryDelay.restart()
    }
    // No breadcrumb yet: nothing to recover, and nothing to protect.
    onLoadFailed: root.recovered = true
  }

  onIdleServiceChanged: {
    if (!idleStateReady) return
    if (root.pendingRecovery) recoveryDelay.restart()
    else syncIdleHold()
  }

  onIdleStateReadyChanged: {
    if (!idleStateReady) return
    if (root.pendingRecovery) recoveryDelay.restart()
    else syncIdleHold()
  }

  // `stayAwakeStateLoaded` turns true on the idle service's first apply from
  // any source, which can be an IPC call that lands before its own file probe
  // does. The probe follows within a few hundred milliseconds, so recovery
  // waits a little past that rather than racing it.
  Timer {
    id: recoveryDelay
    interval: 1500
    repeat: false
    onTriggered: {
      root.tryRecover()
      root.syncIdleHold()
    }
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
    onTriggered: {
      root.expireDue()
      root.heartbeat()
    }
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

  // Whether the plugin's entry is still in the config the shell holds. Gone
  // means this destruction is a disable or a remove, not a shell going down
  // or a plugin reload.
  function stillEnabled() {
    if (!shell || !shell.shellConfig) return true
    var entry = SessionModel.settingsFor(shell.shellConfig, root.pluginId)
    for (var key in entry) return true
    return false
  }

  // The last word before the instance goes. Switched off by the user, the
  // holds go with it and must not be rebuilt when it is switched back on.
  // Otherwise the breadcrumb is written again, seconds old, so a reload or a
  // clean restart finds the holds however long ago they were taken. Written
  // through the FileView, synchronously, because a child process started
  // this late may never get to run.
  function leaveBreadcrumb() {
    if (root.sessions.length === 0) return
    if (root.stillEnabled()) {
      root.log("leaving a breadcrumb with " + root.sessions.length + " held on the way out")
      holdState.setText(root.breadcrumbText(SessionModel.persistableSessions(root.sessions),
        !!root.holdingIdle, !!root.userStayAwake, !!root.suppressingScreensaver) + "\n")
      return
    }
    root.log("plugin disabled with " + root.sessions.length + " held; forgetting them")
    holdState.setText(root.breadcrumbText([], false, false,
      !!root.suppressingScreensaver && root.standingScreensaverOff) + "\n")
  }

  Component.onDestruction: {
    leaveBreadcrumb()
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
