import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "SessionModel.js" as SessionModel

// The session engine. Holds a list of reasons the machine should stay awake,
// each with a condition that decides when it is over, and drives two levers
// while at least one of them is live:
//
//   idle  — the flag the stock Stay Awake indicator toggles, taken through the
//           first-party omarchy.idle service where the shell hands it over,
//           and through `omarchy toggle idle` where it does not.
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

  // Omarchy 4.0.3 narrowed the plugin API. A first-party service is handed out
  // only to a plugin of kind `bar` or to an Indicators clone (shell.qml's
  // pluginFirstPartyServiceFor and createScopedPluginShell); a service +
  // bar-widget plugin gets null from serviceFor and from firstPartyServiceFor
  // alike. Both are still asked, so the in-process route comes back by itself
  // if a later Omarchy grants it.
  readonly property var hostIdleService: !shell ? null
    : ((typeof shell.firstPartyServiceFor === "function"
        ? shell.firstPartyServiceFor("omarchy.idle") : null)
      || (typeof shell.serviceFor === "function" ? shell.serviceFor("omarchy.idle") : null))
  // The flag is only a file, and `omarchy toggle idle` is its supported
  // interface — the same one omarchy-update-stay-awake drives — so the lever is
  // still reachable when the service is not. `flagIdle` stands in with the
  // small surface the rest of this file asks of a service.
  readonly property var idleService: hostIdleService || flagIdle
  readonly property bool usingFlagLever: !hostIdleService

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
  // A screensaver hold falls back to the idle flag when the shell will not let
  // this plugin write idle.screensaver: it is then the only lever that stops
  // the screensaver, and it stops the lock with it. Better a hold that is
  // wider than asked and says so than a switch that does nothing.
  readonly property bool wantIdleHold: SessionModel.anyHolds(sessions, "idle")
    || (wantScreensaverOff && screensaverWriteRefused)
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
  // Set once the shell has refused a write to idle.screensaver. This is what
  // the host allows, not a state that toggles back, so it is never cleared.
  property bool screensaverWriteRefused: false
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
  // One write per turn of the event loop: a hold's start or end changes
  // several things in a row, and the breadcrumb should carry the state at
  // the end of that, never a half of it.
  property bool persistQueued: false
  // This boot. A breadcrumb from before a reboot is never taken for a live
  // shell's, however the pids compare, and a reboot lets go of the holds it
  // interrupted instead of bringing back a machine that never sleeps.
  property string bootId: ""


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
    // Before recovery has run, "off" means the holds the breadcrumb was about
    // to bring back as much as any live ones: they are let go, and a flag it
    // says was held is released.
    if (root.pendingRecovery) {
      var saved = root.pendingRecovery
      var count = Array.isArray(saved.sessions) ? saved.sessions.length : 0
      root.pendingRecovery = null
      root.recovered = true
      recoveryFallback.stop()
      recoverScreensaver(saved.screensaver)
      if (count > 0) root.log("let go of " + count + (count === 1 ? " hold" : " holds") + " a restart was about to bring back: " + reason)
      if (saved.holding === true && root.idleService && !root.holdingIdle) {
        root.applyingIdleHold = true
        root.idleService.setIdleEnabled(true)
        root.applyingIdleHold = false
      }
      root.persistState()
      if (sessions.length === 0) return count > 0 ? "ended " + count : "none"
    }
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
    var pending = root.pendingRecovery && Array.isArray(root.pendingRecovery.sessions) && root.pendingRecovery.sessions.length > 0
    if (sessions.length > 0 || pending) return endAll("switched off")
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
    if (root.pendingRecovery) { if (!recoveryDelay.running) recoveryDelay.start(); return }

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
  //
  // The mutator round-trips through shell.json: it sets shellConfig in memory
  // and persists it, and the config FileView's own change watcher then reloads
  // that write, reloading every plugin a second time. A value already sitting
  // at the target costs the same two reloads as a real change, so a recovery
  // or teardown path that "restores" what is already restored (a second
  // instance settling after a shell restart, a destroyed instance whose value
  // another write already fixed) turns into another round of teardown and
  // construction across the whole registry — the mechanism behind the
  // restart storm that wedged the idle monitor on 2026-09-07. Skipping a
  // no-op write closes that loop without changing any real transition.
  function writeScreensaverSeconds(value) {
    if (!shell || typeof shell.mutateShellConfig !== "function") return false
    if (root.configuredScreensaverSeconds === value) return true
    // The facade keeps the method and refuses the work: under 4.0.3
    // `_mutateBarConfig` is gated on kind `bar`, so this returns false for a
    // service + bar-widget plugin. Reporting that honestly is what keeps the
    // caller from latching a suppression that never happened.
    return shell.mutateShellConfig(function(copy) {
      if (!copy.idle || typeof copy.idle !== "object") copy.idle = {}
      copy.idle.screensaver = value
    }) !== false
  }

  function syncScreensaverHold() {
    if (!shell || typeof shell.mutateShellConfig !== "function") return

    if (root.wantScreensaverOff && !root.suppressingScreensaver) {
      var saving = SessionModel.realScreensaverSeconds(
        root.configuredScreensaverSeconds, root.savedScreensaverSeconds)
      // Nothing is claimed until the write lands. Latching first and writing
      // afterwards is what left the panel reporting a suppression that was
      // never applied, with the guard above making it permanent.
      if (!root.writeScreensaverSeconds(root.screensaverSentinel)) {
        if (!root.screensaverWriteRefused) {
          root.screensaverWriteRefused = true
          root.log("the shell will not let this plugin write idle.screensaver; holding the idle flag instead, which stops the lock with it")
        }
        root.persistState()
        return
      }
      root.savedScreensaverSeconds = saving
      root.suppressingScreensaver = true
      root.log("screensaver off (was " + root.savedScreensaverSeconds + "s)")
      root.persistState()
    } else if (!root.wantScreensaverOff && root.suppressingScreensaver) {
      var restored = SessionModel.realScreensaverSeconds(0, root.savedScreensaverSeconds)
      // A refused restore means the timeout really is still at the sentinel,
      // so the suppression stands and the panel keeps saying so.
      if (!root.writeScreensaverSeconds(restored)) {
        root.log("the shell refused to put idle.screensaver back; it stands at " + root.configuredScreensaverSeconds + "s")
        return
      }
      root.suppressingScreensaver = false
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
      // The flag is gone, so this instance no longer holds it. Recording that
      // before the sessions end matters once the screensaver folds onto this
      // lever: the standing switch would otherwise keep wantIdleHold true, no
      // change would reach syncIdleHold, and the plugin would go on reporting
      // a hold on a flag that is not there.
      root.holdingIdle = false
      // The stock indicator drives the same lever the screensaver switch has
      // to borrow when the timeout is out of reach, so switching it off puts
      // that switch back as well rather than leaving the two to fight.
      if (root.screensaverWriteRefused && root.standingScreensaverOff) {
        root.standingScreensaverOff = false
        root.log("the screensaver switch goes back on with it: on this build the two share one lever")
      }
      root.endAll("Stay Awake was switched off")
    }
  }

  // No parameters on purpose: a parameter that shadows a property of the same
  // name on this object silently resolves to the property, and QML gives no
  // warning. Reading the state straight off `root` cannot go wrong that way.
  function breadcrumbText(sessions, holdingFlag, restoreTo, suppressed, clean) {
    return JSON.stringify({
      holding: holdingFlag,
      restoreTo: restoreTo,
      shellPid: Quickshell.processId,
      bootId: root.bootId,
      clean: clean === true,
      inhibitorPid: sleepInhibitor.running ? sleepInhibitor.processId : 0,
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
    if (!root.recovered || root.persistQueued) return
    root.persistQueued = true
    Qt.callLater(root.flushState)
  }

  function flushState() {
    root.persistQueued = false
    if (!root.recovered) return
    root.lastPersistAt = Date.now()
    var payload = root.breadcrumbText(SessionModel.persistableSessions(root.sessions),
      !!root.holdingIdle, !!root.userStayAwake, !!root.suppressingScreensaver, false)
    // Setting `running` on a Process that is already running does nothing, and
    // the replaced command is simply lost, so a write that lands while one is
    // in flight waits its turn, and the last one stands.
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
      'mkdir -p "$1" && printf "%s\\n" "$2" > "$1/hold.tmp" && mv -f "$1/hold.tmp" "$1/hold"',
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

  function tryRecover(force) {
    if (!root.pendingRecovery) return
    var idle = root.idleService
    if (!force && (!idle || !root.idleStateReady)) return
    if (root.bootId === "") root.bootId = String(bootIdFile.text() || "").trim()

    var saved = root.pendingRecovery
    root.pendingRecovery = null
    root.recovered = true
    recoveryFallback.stop()
    var now = Date.now()
    var sameBoot = !saved.bootId || saved.bootId === root.bootId
    var deadShell = !sameBoot || Number(saved.shellPid) !== Quickshell.processId
    var flagOn = !!idle && idle.stayAwake === true
    // The user's own setting is trusted only from an orderly exit; a crash
    // leaves whatever the last asynchronous write said, which may be stale.
    var priorOn = saved.clean === true && saved.restoreTo === true
    var savedAt = !sameBoot ? 0 : (deadShell ? saved.savedAt : now)
    var savedCount = Array.isArray(saved.sessions) ? saved.sessions.length : 0
    root.log("recovering after a " + (!sameBoot ? "reboot" : (deadShell ? "shell restart" : "shell reload")) + ": the breadcrumb "
      + (saved.holding === true ? "held" : "did not hold") + " the flag, the flag is " + (flagOn ? "on" : "off") + ", " + savedCount + " saved")

    // The sessions are worked out before the screensaver is, because the answer
    // for the screensaver depends on them. A session-scoped suppression whose
    // session is coming back must not be restored first and suppressed again a
    // moment later: the pair nets to nothing on disk, but each write is a
    // config round-trip that reloads every plugin and rebuilds the idle
    // service's monitor, and rebuilding it twice inside a few milliseconds is
    // what leaves it silent.
    var restored = SessionModel.restoreSessions(saved.sessions, savedAt, now, defaults())
    var keeping = !restored.stale && restored.sessions.length > 0

    recoverScreensaver(saved.screensaver, keeping && SessionModel.anyHolds(restored.sessions, "screen"))
    if (deadShell) reapInhibitor(saved.inhibitorPid)

    var wantsIdle = keeping && SessionModel.anyHolds(restored.sessions.concat(root.sessions), "idle")
    // A hold the last instance took is a leak whenever this one does not hold,
    // and a flag found on while the kept holds want it is taken as ours too:
    // a hold that was starting when the shell died leaves it exactly so.
    var leftHolding = !root.holdingIdle && (saved.holding === true || (wantsIdle && flagOn && !priorOn))

    if (idle && leftHolding && wantsIdle) {
      root.log("adopting the idle hold left by the last instance, for the holds being kept")
      root.userStayAwake = priorOn
      root.holdingIdle = true
      root.idleHeldAt = now
      root.reassertedIdle = false
      root.applyingIdleHold = true
      idle.setIdleEnabled(false)
      root.applyingIdleHold = false
    } else if (idle && leftHolding) {
      root.log(priorOn ? "giving the idle flag back to the user after the last instance's hold"
        : "releasing an idle hold left behind by the last instance")
      root.applyingIdleHold = true
      idle.setIdleEnabled(!priorOn)
      root.applyingIdleHold = false
    }

    if (!sameBoot && savedCount > 0) root.log("a new boot: the " + savedCount + (savedCount === 1 ? " hold" : " holds") + " from before it are let go")
    else if (restored.stale && savedCount > 0) root.log("not restoring holds from a breadcrumb older than the restore window")
    if (restored.expired.length > 0) finish(restored.expired, "the time was up while the shell was away")
    if (keeping) {
      // Holds started in the moments before recovery stay; the restored ones
      // join them, renumbered only where an id is already taken.
      var merged = root.sessions.slice()
      var nextId = Math.max(root.nextSessionId, restored.nextId)
      for (var i = 0; i < restored.sessions.length; i++) {
        var session = restored.sessions[i]
        var taken = merged.some(function(m) { return m.id === session.id })
        if (taken) { session.id = String(nextId); nextId += 1 }
        merged.push(session)
      }
      root.nextSessionId = nextId
      root.sessions = merged
      root.log("kept " + restored.sessions.length + (restored.sessions.length === 1 ? " hold" : " holds")
        + " across a shell " + (deadShell ? "restart" : "reload") + ": " + SessionModel.sessionLabels(restored.sessions))
      Qt.callLater(root.checkConditions)
    }
    root.persistState()
  }

  // A sleep inhibitor is a child process, and a shell that dies abnormally
  // leaves it running with nothing to release it. The next instance stops
  // the one the breadcrumb names, after checking the pid is still ours.
  function reapInhibitor(pid) {
    var id = Number(pid)
    if (!(id > 1)) return
    reaper.command = ["bash", "-c", 'if grep -qa "Stay Awake Sessions" "/proc/$1/cmdline" 2>/dev/null; then kill "$1" && echo reaped; fi',
      "stay-awake-sessions", String(Math.floor(id))]
    reaper.running = true
  }

  Process {
    id: reaper
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() === "reaped") root.log("stopped a sleep inhibitor left running by the last instance")
    }
  }

  // ------------------------------------------------- the idle flag as a file

  // Where Omarchy keeps the flag. The stock indicator, `omarchy toggle idle`
  // and omarchy-update-stay-awake all mean this one file.
  readonly property string indicatorsDir: Quickshell.env("HOME") + "/.local/state/omarchy/indicators"

  // The stand-in for omarchy.idle. It carries only what the rest of this file
  // asks of a service — `stayAwake`, `stayAwakeStateLoaded`, setIdleEnabled() —
  // so every call site is unchanged whichever lever is in use.
  QtObject {
    id: flagIdle
    property bool stayAwake: false
    property bool stayAwakeStateLoaded: false
    // The argument is idle *enabled*, so the flag is its inverse: enabling idle
    // lets go of the flag, disabling idle takes it.
    function setIdleEnabled(enabled) {
      idleFlagWriter.command = ["omarchy-toggle-idle", enabled ? "allow-idle" : "stay-awake"]
      idleFlagWriter.running = true
    }
  }

  function refreshIdleFlag() {
    if (!idleFlagProbe.running) idleFlagProbe.running = true
  }

  // Read the way the first-party service reads it: probe the file, and watch
  // the directory rather than the file, so the flag appearing and disappearing
  // both register. A flip from the stock indicator is noticed here too, which
  // is what lets the "Stay Awake was switched off" path keep working.
  Process {
    id: idleFlagProbe
    command: ["bash", "-c",
      'mkdir -p "$1"; if [[ -f "$1/stay-awake" ]]; then echo yes; else echo no; fi',
      "stay-awake-sessions", root.indicatorsDir]
    stdout: SplitParser {
      onRead: function(line) {
        flagIdle.stayAwake = String(line).trim() === "yes"
        flagIdle.stayAwakeStateLoaded = true
      }
    }
  }

  Process {
    id: idleFlagWriter
    // Read back rather than assumed: a write that did not land would otherwise
    // leave the plugin reporting a hold it does not have, which is the failure
    // that hid the 4.0.3 breakage for a morning.
    onExited: root.refreshIdleFlag()
  }

  FileView {
    id: idleFlagWatcher
    path: root.indicatorsDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshIdleFlag()
  }

  Component.onCompleted: root.refreshIdleFlag()

  // The screensaver splits from the idle flag here. A standing switch is a
  // preference and is meant to outlive the shell, so it is adopted rather than
  // undone — the plugin picks the lever back up and keeps owning it. A
  // session-scoped suppression had a lifetime that died with the shell, so its
  // timeout goes back, or the user's screensaver stays silently dead in
  // shell.json with nothing left to explain it.
  function recoverScreensaver(saver, keptBySession) {
    if (!saver || saver.suppressed !== true) {
      // A timeout sitting at our own sentinel with no record of it is a
      // suppression an earlier instance lost track of. Own it as the standing
      // switch, so the panel tells the truth and the switch can put it back.
      if (root.configuredScreensaverSeconds >= SessionModel.SCREENSAVER_SENTINEL_FLOOR && !root.suppressingScreensaver) {
        root.log("the screensaver timeout was left at the sentinel with no record of it; taking it as the standing switch")
        root.savedScreensaverSeconds = SessionModel.realScreensaverSeconds(0, saver ? saver.original : 0)
        root.suppressingScreensaver = true
        root.standingScreensaverOff = true
      }
      return
    }
    var original = SessionModel.realScreensaverSeconds(0, saver.original)

    if (String(saver.mode) === "standing") {
      root.savedScreensaverSeconds = original
      // The preference comes back either way, but the suppression is adopted
      // only when the timeout really is still at the sentinel. Adopting it on
      // the breadcrumb's word is what made a refused write permanent: it left
      // `suppressing` true, and the guard in syncScreensaverHold then never
      // tried again, across every reload.
      root.suppressingScreensaver = root.configuredScreensaverSeconds >= SessionModel.SCREENSAVER_SENTINEL_FLOOR
      // Assigned last: this is what flips wantScreensaverOff, and the handler
      // it fires must already see whether the suppression is real.
      root.standingScreensaverOff = true
      return
    }

    // Session-scoped, and a session that wants the lever is coming back with
    // this recovery: the suppression carries straight over to it. Restoring the
    // timeout here would only have it written back a moment later, and the
    // round trip is what the reordering above exists to avoid.
    if (keptBySession) {
      root.savedScreensaverSeconds = original
      // Same rule as the standing branch: claim the suppression only if the
      // timeout carries it. The sessions are assigned after this returns, and
      // that is what asks for the lever again if it is not.
      root.suppressingScreensaver = root.configuredScreensaverSeconds >= SessionModel.SCREENSAVER_SENTINEL_FLOOR
      return
    }

    // Session-scoped with nothing coming back: whether the shell died or the
    // plugin merely reloaded, whatever justified the suppression is gone.
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
    id: bootIdFile
    path: "/proc/sys/kernel/random/boot_id"
    blockLoading: true
    printErrors: false
    onLoaded: root.bootId = String(text() || "").trim()
  }

  // Should the idle service never report ready (disabled, or failed to
  // load), the sessions are still recovered, without touching the flag.
  Timer {
    id: recoveryFallback
    interval: 10000
    repeat: false
    onTriggered: {
      if (!root.pendingRecovery || root.recovered) return
      root.log("the idle service has not reported ready; recovering the holds without touching the flag")
      root.tryRecover(true)
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
      else {
        recoveryFallback.restart()
        if (root.idleStateReady) recoveryDelay.restart()
      }
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
      idleServiceReachable: !!root.hostIdleService,
      idleLever: root.usingFlagLever ? "flag" : "service",
      screensaverLever: root.screensaverWriteRefused ? "idle-flag" : "timeout",
      holdingIdleFlag: root.holdingIdle,
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
    if (root.stillEnabled()) {
      // Enabled: a recovered instance writes what it knows, holds or none, so
      // no older breadcrumb outlives it; one that never recovered leaves the
      // last good breadcrumb for the next.
      if (!root.recovered) return
      holdState.setText(root.breadcrumbText(SessionModel.persistableSessions(root.sessions),
        !!root.holdingIdle, !!root.userStayAwake, !!root.suppressingScreensaver, true) + "\n")
      return
    }
    // Disabled or removed: the holds go, including ones a recovery that never
    // ran was about to bring back, and a flag such a breadcrumb says was held
    // is released here, while the idle service is still reachable.
    var pending = root.pendingRecovery
    var pendingCount = pending && Array.isArray(pending.sessions) ? pending.sessions.length : 0
    if (root.sessions.length > 0 || pendingCount > 0) root.log("plugin disabled with " + (root.sessions.length + pendingCount) + " held; forgetting them")
    holdState.setText(root.breadcrumbText([], false, false,
      !!root.suppressingScreensaver && root.standingScreensaverOff, true) + "\n")
    if (!root.holdingIdle && pending && pending.holding === true && root.idleService) {
      root.applyingIdleHold = true
      root.idleService.setIdleEnabled(true)
      root.applyingIdleHold = false
    }
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
