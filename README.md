# Stay Awake Sessions

An Omarchy 4 (Quattro) shell plugin that keeps this machine awake **for a reason
that ends by itself**.

Omarchy already ships a Stay Awake toggle. A toggle is a switch you have to
remember to flip back, and the thing people actually want is the one Amphetamine
sold on macOS: *stay awake **while** this is true*. A deadline, a build, a
container, a login session. When the reason is over, the hold is over.

```bash
stay-awake for 90m                       # until half past
stay-awake until 5pm                     # until a time of day
stay-awake while -- cargo test           # exactly as long as the command runs
stay-awake while-app mpv                 # while an app has a window open
stay-awake while-process ffmpeg          # while a process is alive
stay-awake while-command 'who | grep -q pts'   # while any condition holds
```

The bar widget shows what is holding the machine and how long is left. Every
hold ends with a notification saying why.

![The bar widget and its panel, holding two sessions](preview.png)

## Install

```bash
omarchy plugin add https://github.com/Ignibyte/omarchy-stay-awake-sessions.git
omarchy plugin enable ignibyte.stay-awake-sessions right
```

The plugin lands disabled so you can read the code first, which is worth doing:
Omarchy plugins run unsandboxed inside `omarchy-shell`, with your permissions.

For the command line, put its `bin` on your `PATH`:

```bash
ln -s ~/.config/omarchy/plugins/ignibyte.stay-awake-sessions/bin/stay-awake ~/.local/bin/stay-awake
```

### Removal

```bash
omarchy plugin disable ignibyte.stay-awake-sessions
omarchy plugin remove ignibyte.stay-awake-sessions
rm -f ~/.local/bin/stay-awake
rm -rf ~/.local/state/omarchy/stay-awake-sessions
```

Disabling releases any hold the plugin is keeping, so the machine goes back to
its usual timers. Nothing outside those paths is touched: the plugin writes only
its own state directory and the Stay Awake flag Omarchy already owns, and it
adds one entry to `~/.config/omarchy/shell.json`, which `omarchy plugin remove`
takes back out.

### Requirements

Omarchy 4 (Quattro). Beyond what Omarchy already installs, it uses `bash`,
`pgrep` (procps-ng), `systemd-inhibit` and `notify-send` (libnotify) — all
present on a stock Omarchy box. The CLI wrapper also uses `jq`. The session
logic in `SessionModel.js` runs under node: `node test/session-model-test.js`.

## The bar widget

| | |
|---|---|
| Left click | Open the panel: what is held, the quick holds, a box to type a duration or a time, and a picker of open apps |
| Right click | Hold for the default duration, or release everything |
| Middle click | Release everything |

While nothing is held the cup sits dimmed in the bar. While something is, it
lights up and carries the next deadline beside it (`󰅶 1h 04m`), or the name of
whatever is holding it when there is no deadline.

## Holds

Every hold is a **session**: a label, a condition, and what it blocks.

| Condition | What ends it |
|---|---|
| `for <duration>` | The clock. `90m`, `2h`, `1h30m`, `45s`, or a bare number as minutes |
| `until <time>` | A time of day — `17:00`, `5pm`, `5:30pm` — today or tomorrow, whichever is next |
| `while -- <command>` | The command exiting. No polling: the hold is tied to the child process |
| `while-app <name>` | The app's last window closing |
| `while-process <pattern>` | No process matches the pattern any more (`pgrep -f`) |
| `while-command <shell>` | The command stops exiting 0 |
| `on` | Nothing. It holds until you end it |

`while-app` is the one Amphetamine users will look for. It matches the app id
or the window title, case-insensitively, and reads the compositor's own list of
open windows rather than guessing from process names — so it ends when the last
window closes, not when some background helper exits. `stay-awake apps` prints
what is open right now, and the panel offers the same list as a picker.

```bash
stay-awake apps
stay-awake while-app mpv --scope screen --label "Watching something"
```

Conditions are re-checked every few seconds, and a condition is allowed to read
false for a grace period before its hold ends — long enough that the gap between
two `cargo` invocations in one script does not drop the hold.

`stay-awake while -- <command>` is the one to reach for in a script. It needs no
polling and no pattern, because the hold lives and dies with the child process:

```bash
stay-awake while --scope all -- ./bin/gate.sh --full-regression
```

## What a hold blocks

`--scope` picks the lever:

| Scope | Effect |
|---|---|
| `screen` | The screensaver only, where the shell allows it. See below |
| `idle` (default) | The screensaver and the lock, through Omarchy's own Stay Awake flag |
| `sleep` | Suspend and hibernate, through a logind `idle:sleep` inhibitor |
| `all` | `idle` and `sleep` together |

`screen` is the one for watching something. Omarchy's Stay Awake flag stops the
screensaver and the lock together, but their timeouts are two separate numbers
in `shell.json`, so pushing `idle.screensaver` past `idle.lock` stops the
screensaver on its own and leaves the lock firing on schedule:

```bash
stay-awake while-process mpv --scope screen --label "Watching something"
```

On Omarchy 4.0.3 and later that split is gone. The shell hands `shell.json` only
to a plugin of kind `bar`, and this is a widget, so `idle.screensaver` is out of
reach. A `screen` hold falls back to the idle flag there, which means the screen
does not lock either. `stay-awake status` names the lever in use, and the plugin
will not claim a suppression it could not apply.

## The screensaver switch

Some people just never want the screensaver. That is a preference, not a hold,
so it gets its own switch — in the panel, and on the command line:

```bash
stay-awake screensaver off       # the screen still locks on its usual timer
stay-awake screensaver on
stay-awake screensaver toggle
```

The switch persists across restarts, because it edits `idle.screensaver` in
your `shell.json` and puts your own value back when you turn it on again. Your
original timeout is remembered, and the plugin will never mistake its own
suppression for your setting.

Where the shell refuses that write — Omarchy 4.0.3 and later — the switch holds
the idle flag instead, so the screen stops locking as well, and switching Stay
Awake off at the stock indicator puts the switch back with it. The two share one
lever there. `stay-awake status` says as much rather than promising a lock that
still fires.

## Options

Set these on the widget in Setup > Plugins, or on its entry in
`~/.config/omarchy/shell.json`:

| Key | Default | What it does |
|---|---|---|
| `defaultMinutes` | `60` | The right-click hold's length |
| `quickMinutes` | `5, 15, 30, 45` | The minute buttons in the panel, up to six |
| `quickHours` | `1, 2, 4, 8` | The hour buttons in the panel, up to six |
| `defaultScope` | `idle` | What a hold blocks when `--scope` is not given |
| `pollSeconds` | `5` | How often a process or command condition is re-checked |
| `graceSeconds` | `15` | How long a condition may read false before its hold ends |
| `notify` | `true` | Notify when a hold ends |
| `showWhenIdle` | `true` | Keep the cup in the bar when nothing is held |

## How it plays with the stock toggle

The plugin drives the same flag the built-in Stay Awake indicator does, and
hands it back the way it found it. Turn Stay Awake on by hand, run a session,
and when the session ends the flag is still on.

Switching Stay Awake **off** by hand while sessions are running ends them. You
asked for the machine to sleep; the sessions do not argue.

## Surviving a shell restart

Holds outlive the shell. `omarchy-restart-shell`, a plugin reload, a crash, or
the shell relaunching itself all bring the same sessions back: a timed hold
keeps its deadline, an app, process or command hold starts its grace period
again and ends the normal way if the thing it was waiting on is really gone,
and a hold whose time ran out while the shell was away is reported as ended.
The breadcrumb at `~/.local/state/omarchy/stay-awake-sessions/hold` carries the
sessions along with the flag. It is rewritten once a minute while anything is
held and once more as the plugin unloads, and a new shell rebuilds the holds
when it is less than fifteen minutes old, so a hold taken in the morning comes
back after an afternoon restart while a reboot or a plugin switched back on
the next day starts clean. Disabling the plugin forgets them on the spot.

The flag itself is handled more carefully than the sessions. If the shell dies
while a hold is live, the Stay Awake flag would outlive the process that took
it, leaving a machine that never sleeps and nothing on screen to say why. A new
shell that finds a hold in the breadcrumb and sessions to rebuild adopts the
flag as its own; one with nothing to rebuild releases it. Recovery after a
crash only ever releases: there is no way to tell a flag you set by hand from
one a dead hold left switched on, and of the two possible mistakes, a machine
that never sleeps is the worse one. After a plugin reload the breadcrumb was
written by the same shell moments earlier, so what it recorded as your own
setting is trusted and given back.

The shell reloads every plugin, its own idle service included, whenever a file
in any local plugin changes, and it does so from the components it already
compiled, so a code change still needs `omarchy-restart-shell`. Holds survive
that reload too, and two reloads back to back: a new instance writes nothing
to the breadcrumb until it has read the old one and acted on it, so an
instance unloaded again before that moment leaves the last good breadcrumb
for the next.

The breadcrumb also carries the boot it was written in. After a reboot the
holds it names are let go and a flag it says was held is released, however
quickly the machine came back; a machine that never sleeps because of a hold
from before a reboot was the mistake to avoid. A hold started in the first
moments after a restart is kept alongside the ones being brought back, and
`stay-awake off` in those moments lets the pending ones go too. Disabling the
plugin in those moments still forgets them and releases the flag. A sleep
inhibitor left running by a shell that died abnormally is stopped by the
next instance. And a screensaver timeout found sitting at the plugin's own
sentinel with no record of it is taken as the standing switch, so the panel
says "off" and the switch can put it back. The reverse is checked too: a
breadcrumb that says a suppression was in force is believed only if the
timeout still carries it, so a write the shell refused cannot come back as a
suppression that never happened.

## From the command line without the wrapper

The plugin registers a `stayawake` IPC target:

```bash
omarchy-shell stayawake status
omarchy-shell stayawake list
omarchy-shell stayawake hold 'for=90m label="Render" scope=all'
omarchy-shell stayawake hold '{"while-process":"ffmpeg","label":"Encoding"}'
omarchy-shell stayawake hold 'while-app=mpv'
omarchy-shell stayawake apps
omarchy-shell stayawake screensaver off
omarchy-shell stayawake end 3
omarchy-shell stayawake endAll
omarchy-shell stayawake toggle
```

A spec is either `key=value` pairs or JSON. `hold` returns the new session's id.

## Development

The plugin is a git checkout in `~/.config/omarchy/plugins/`. Saving a file is
meant to reload the plugin in place, but that reload is known to get stuck;
`omarchy-restart-shell` is the reliable way to load a change, and since 0.5.0
the holds come back after it. `node test/session-model-test.js` runs the
session logic without a shell.

`SessionModel.js` holds every decision about durations, conditions and
formatting as plain functions, so the logic can be read and exercised without a
running shell. `Service.qml` owns the sessions and the two levers. `BarWidget.qml`
is the face. `bin/eval-predicates` checks every watched condition in one pass;
it takes its table base64-encoded on argv on purpose, because a pattern passed
in the clear would sit in the checker's own command line and `pgrep -f` would
match the process doing the matching.

## Licence

MIT. See [LICENSE](LICENSE).
