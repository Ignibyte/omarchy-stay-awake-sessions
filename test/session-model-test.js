// node test/session-model-test.js
// SessionModel.js is a QML library (`.pragma library`), so it is loaded here
// with that first line removed and its functions read back off the sandbox.
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "SessionModel.js"), "utf8").replace(/^\.pragma library\s*\n/, "")
const sandbox = {}
vm.createContext(sandbox)
vm.runInContext(source, sandbox)
const Model = sandbox

let passed = 0
function check(name, fn) { fn(); passed += 1; console.log("  ok  " + name) }

const defaults = { scope: "idle", graceSeconds: 15 }
const now = 1_800_000_000_000

check("a session round-trips through the breadcrumb", () => {
  const built = Model.buildSession(Model.parseSpec("while-app=com.ignibyte.rusty scope=all grace=30"), defaults, now - 60000, 7)
  const saved = Model.persistableSessions([built])
  assert.strictEqual(saved[0].id, "7")
  assert.strictEqual(saved[0].app, "com.ignibyte.rusty")
  assert.strictEqual(saved[0].lastTrueAt, undefined, "runtime fields stay out of the file")
  const restored = Model.restoreSessions(JSON.parse(JSON.stringify(saved)), now - 5000, now, defaults)
  assert.strictEqual(restored.stale, false)
  assert.strictEqual(restored.sessions.length, 1)
  const back = restored.sessions[0]
  assert.strictEqual(back.id, "7"); assert.strictEqual(back.kind, "app"); assert.strictEqual(back.scope, "all")
  assert.strictEqual(back.graceSeconds, 30); assert.strictEqual(back.startedAt, now - 60000)
  assert.strictEqual(back.lastTrueAt, now, "the grace period starts afresh")
  assert.strictEqual(restored.nextId, 8)
  assert.strictEqual(Model.describe(back), "while com.ignibyte.rusty is open")
})

check("timed holds keep their deadline, and one that passed is reported, not kept", () => {
  const live = Model.buildSession(Model.parseSpec("for=90m label=Render"), defaults, now - 10 * 60000, 1)
  const gone = Model.buildSession(Model.parseSpec("for=5m"), defaults, now - 10 * 60000, 2)
  const restored = Model.restoreSessions(Model.persistableSessions([live, gone]), now - 20000, now, defaults)
  assert.strictEqual(restored.sessions.length, 1)
  assert.strictEqual(restored.sessions[0].label, "Render")
  assert.strictEqual(restored.sessions[0].expiresAt, now + 80 * 60000)
  assert.strictEqual(restored.expired.length, 1)
  assert.strictEqual(restored.expired[0].id, "2")
  assert.strictEqual(restored.nextId, 3)
})

check("a stale breadcrumb rebuilds nothing", () => {
  const manual = Model.buildSession(Model.parseSpec(""), defaults, now, 3)
  const saved = Model.persistableSessions([manual])
  assert.strictEqual(Model.restoreSessions(saved, now - 16 * 60000, now, defaults).stale, true)
  assert.strictEqual(Model.restoreSessions(saved, now - 14 * 60000, now, defaults).sessions.length, 1)
  assert.strictEqual(Model.restoreSessions(saved, undefined, now, defaults).stale, true, "no timestamp is no trust")
  assert.strictEqual(Model.restoreSessions(saved, now + 60000, now, defaults).stale, false, "a clock that stepped back a minute is tolerated")
  assert.strictEqual(Model.restoreSessions(saved, now + 10 * 60000, now, defaults).stale, true, "a breadcrumb ten minutes in the future is no trust")
  const dup = Model.restoreSessions([{ kind: "manual", id: "2", label: "a" }, { kind: "manual", label: "b" }, { kind: "manual", id: "2", label: "c" }], now - 1000, now, defaults)
  assert.strictEqual(JSON.stringify(dup.sessions.map(s => s.id)), JSON.stringify(["2", "3", "4"]), "ids come back unique")
  // Objects made inside the sandbox have another realm's prototype, so compare the JSON.
  assert.strictEqual(JSON.stringify(Model.restoreSessions([], now, now, defaults)), JSON.stringify({ sessions: [], expired: [], nextId: 1, stale: false }))
  assert.strictEqual(Model.restoreSessions(undefined, now, now, defaults).sessions.length, 0)
})

check("damaged entries are skipped and labels are filled in", () => {
  const saved = [
    { id: "4", kind: "process", pattern: "ffmpeg", scope: "sleep" },
    { id: "5", kind: "process", pattern: "" },
    { id: "6", kind: "nonsense" },
    { id: "7", kind: "timed", expiresAt: 0 },
    { id: "8", kind: "manual" },
    null
  ]
  const restored = Model.restoreSessions(saved, now, now, defaults)
  assert.strictEqual(JSON.stringify(restored.sessions.map(s => s.id)), JSON.stringify(["4", "8"]))
  assert.strictEqual(restored.sessions[0].label, "ffmpeg")
  assert.strictEqual(restored.sessions[0].graceSeconds, 15)
  assert.strictEqual(restored.sessions[1].label, "Until you stop it")
  assert.strictEqual(Model.sessionLabels(restored.sessions), "ffmpeg, Until you stop it")
  assert.strictEqual(restored.nextId, 9)
})

console.log(passed + " checks passed")
