# AGENTS.md — derfleischmann.shutdown-timer

Guidance for agents and humans editing this Omarchy (Quattro / Quickshell) bar
plugin. Read this before touching `Service.qml`, `BarWidget.qml`, or
`Model.js`. `README.md` is the user-facing description; this file is the
maintainer's map and the list of invariants that must not be broken.

## What this is

A `service` + `bar-widget` plugin that shuts the machine down after a countdown.
Its entire reason to exist is that the countdown, the cancel button, and the
actual poweroff must never disagree.

The design is deliberately small:

- the shell **arms one user-scoped systemd timer**;
- that timer is the **only** thing that can power the machine off;
- the shell's countdown is a **pure view** over the timer;
- cancel stops the timer and then **re-reads the unit** to confirm.

No sudo, no pkexec, no system units, no network, no state file.

## Layout

- `manifest.json` — id `derfleischmann.shutdown-timer`, kinds `service` and
  `bar-widget`, `keepLoaded: true`, one `notify` boolean setting.
- `Model.js` — pure functions and the fixed argv builders. Node-testable with
  `node --test tests/model.test.js`. This is where every safety-relevant
  decision (duration bounds, command shape, output parsing) lives.
- `Service.qml` — singleton state machine: arm/cancel/verify, the 15 s
  reconciliation probe, notifications, IPC.
- `BarWidget.qml` — bar icon, countdown label, `KeyboardPanel` UI,
  `ConfirmDialog`.
- `tests/model.test.js` — 13 Node tests; keep them green.
- `.github/workflows/test.yml` — CI: runs the Node tests on every push/PR.

## Invariants — breaking these defeats the point of the plugin

1. **One trigger only.** The QML layer must never call `poweroff`, `reboot`,
   `systemctl poweroff`, or `loginctl`. It arms a systemd timer and then watches
   it. The moment a second code path can power off the machine, cancel races
   reappear and the plugin is no safer than the one it replaces.
2. **Systemd is the source of truth.** There is no state file. `status` is
   derived from `systemctl --user --timestamp=unix show <unit>.timer`. Never add
   a file whose contents can override what systemd reports.
3. **Wall clock, not `--on-active`.** Use `--on-calendar=@<epoch>`. `--on-active`
   silently stretches across suspend and after NTP steps, so the displayed
   countdown and the real deadline diverge. `--on-calendar=@<epoch>` keeps them
   identical.
4. **Cancel is verify-then-report.** `cancel()` stops the unit, re-reads it, and
   reports failure if it is still armed. Never show "cancelled" because a `stop`
   command exited 0.
5. **No shell, no PATH.** Every command is a fixed argv array with an absolute
   program path (`/usr/bin/systemd-run`, `/usr/bin/systemctl`,
   `/usr/share/omarchy/bin/omarchy-system`,
   `/usr/share/omarchy/bin/omarchy-notification-send`). No `sh -c`, no string
   interpolation, no `PATH` lookup.
6. **Durations are bounded integers.** `MIN_SECONDS = 60`,
   `MAX_SECONDS = 86400`. Below the minimum is rejected (return `0`), above the
   maximum is capped. Do not "helpfully" promote a rejected value to the
   minimum.
7. **IPC stays read-only plus cancel.** The service exposes `status`,
   `remaining`, and `cancel`. There is intentionally **no remote `start`**: a
   same-user process must not be able to schedule a poweroff through this
   plugin. Starting is panel-only and requires confirmation.
8. **The confirm dialog defaults to Cancel.** `ConfirmDialog.selectedIndex: 0`
   maps to Cancel. Keep it that way.
9. **Untrusted text never becomes markup.** Use `Text.PlainText` for labels and
   dialog messages. Durations are formatted from bounded numbers.
10. **Leaving the timer armed is a feature.** `Component.onDestruction` does
    nothing on purpose: a shell restart must not cancel a shutdown the user
    asked for. The next shell instance adopts the timer via its startup probe.

## State machine

```
start(n)
  clampSeconds(n) -> pendingDeadline = now + n*1000
  beginOp("arm") -> stop -> reset-failed -> systemd-run -> show

show (arm mode)
  parse ActiveState / NextElapseUSecRealtime / ActiveEnterTimestamp
  require isArmed() && deadlineValid() && |deadline - pendingDeadline| <= 3000
  adopt() and notify "Shutdown scheduled"

cancel()
  beginOp("cancel") -> stop -> reset-failed -> show

show (cancel mode)
  if still armed -> lastError, do NOT clear
  else clear() and notify "Shutdown cancelled"
```

`probe()` runs every 15 s (and once on `Component.onCompleted`). It re-adopts a
live unit after a shell restart or an external `systemctl stop`, and clears the
UI with an explicit error if the unit vanished mid-countdown.

`tick()` runs every 500 ms while active. At zero it **only** sets
`active = false; expired = true`. It does not shut down. `checkExpired()` gives
systemd 20 s to act, then reports that the machine is still running.

## Omarchy / Quickshell facts this plugin depends on

Established while building this on Omarchy 4.5.0-3 (systemd 262). Re-verify
after a shell upgrade.

- **`Ui/BarWidget` has no `fontFamily`.** The base exposes `bar`,
  `moduleName`, `settings`, `fixedEdge`, `vertical`, `barSize`. Define
  `readonly property string fontFamily: Style.font.family` on the widget root
  yourself, or every `fontFamily:` assignment warns `Unable to assign
  [undefined] to QString`.
- **The service property is `remainingSec`, not `remainingSeconds`.** The IPC
  JSON uses `remainingSeconds` as a payload key; the QML property is
  `remainingSec`. Mixing them assigns `undefined` to an `int` and the countdown
  silently breaks.
- **`BarIconButton.text` is the glyph.** The readable countdown belongs in
  `labelText`; `text` is passed to `OpticalGlyph`. Grow `slotSize` when a label
  is shown (the stock battery widget does
  `slotSize: Style.bar.iconSlot * (showPercentage ? 2 : 1)`).
- **`IpcHandler` needs `import Quickshell.Io`.** Without it the component fails
  to load with `IpcHandler is not a type`.
- **`QS_DISABLE_FILE_WATCHER=1` is set by `omarchy-launch-shell`.** A running
  shell can keep serving a stale compiled component after you edit a plugin
  file, especially after changing imports (line numbers in the error point at
  the old file). The reliable fix is `omarchy restart shell`.
  `omarchy-shell shell rescanPlugins` is worth trying first but is not
  trustworthy for import changes.
- **`systemctl --user --timestamp=unix show` prints `@<epoch>`.** Properties
  come out alphabetically, not in the order requested. Parse `Key=Value` lines;
  do not rely on order. A missing/inactive transient timer reports
  `ActiveState=inactive` and an empty `NextElapseUSecRealtime`.
- **Transient user units inherit the session environment.** Verified:
  `XDG_RUNTIME_DIR`, `HYPRLAND_INSTANCE_SIGNATURE`, `WAYLAND_DISPLAY`, `PATH`,
  `OMARCHY_PATH` are all present, so `omarchy-system shutdown` works from the
  timer.
- **Polkit allows power-off from a user unit here.** Verified with `pkcheck`
  from a transient user unit (`org.freedesktop.login1.power-off` → exit 0) and
  `systemctl poweroff --dry-run`. Do not add sudo to "fix" a hypothetical
  denial; if a future policy changes, surface the failure, do not escalate.
- **`omarchy-system shutdown` is the right binary.** There is no
  `omarchy-system-shutdown` on this system. With no second argument,
  `omarchy-system shutdown` spawns its own bounded `systemd-run --user` unit
  (`RuntimeMaxSec=30s`) that closes windows and calls
  `systemctl poweroff --no-wall`. Let it do that; do not call `poweroff`
  yourself.
- **Re-arming needs a clean unit.** `systemd-run --unit=<fixed-name>` fails if
  the transient unit still exists. The arm sequence is always
  `stop -> reset-failed -> systemd-run`.
- **`--collect` is required.** It removes the transient units after they finish,
  so a later arm can reuse the fixed unit name.

## Testing without shutting the machine down

Never test the production trigger by waiting for the deadline. Use a harmless
payload with the same unit name and deadline mechanics:

```bash
U=derfleischmann-shutdown-timer
systemctl --user stop $U.timer $U.service 2>/dev/null || true
systemctl --user reset-failed $U.timer $U.service 2>/dev/null || true
systemd-run --user --collect --quiet --unit=$U \
  --on-calendar=@$(( $(date +%s) + 300 )) \
  --timer-property=AccuracySec=1s /bin/true

# let the service adopt it (15 s probe), then:
omarchy-shell derfleischmann.shutdown-timer status   # active:true
omarchy-shell derfleischmann.shutdown-timer cancel
systemctl --user list-timers $U.timer --all          # 0 timers
```

To validate the real arm argv, arm 24 h out with the real binary and stop it
immediately — even a failed cancel leaves a day of margin:

```bash
systemd-run --user --collect --quiet --unit=$U \
  --on-calendar=@$(( $(date +%s) + 86400 )) \
  --timer-property=AccuracySec=1s \
  /usr/share/omarchy/bin/omarchy-system shutdown
systemctl --user stop $U.timer $U.service
```

Always keep `systemctl --user stop ...` as a backstop in the same test.

## Verification checklist

```bash
node --test tests/model.test.js     # 13 tests
omarchy plugin validate .           # manifest + entry points
omarchy restart shell               # pick up edited files
omarchy-shell derfleischmann.shutdown-timer status
journalctl --user -b --no-pager | grep -i shutdown-timer
```

The only acceptable journal line at rest is the benign
`Module path ".../plugins/derfleischmann.shutdown-timer" is outside of the
config folder` scanner warning (all user plugins get it). Any `Plugin widget
... failed`, `IpcHandler is not a type`, or `Unable to assign [undefined]`
warning is a real bug.

## Background: what was fixed versus the plugin this replaces

A reviewed third-party plugin used two independent triggers (its own countdown
plus a systemd timer), which races on cancel near T-0. It also persisted an
unbounded `deadlineMs` in a state file, exposed an unauthenticated IPC `start`,
resolved programs through `PATH`, and swallowed failures. This plugin removes
all five problems:

- single trigger (systemd only);
- no state file;
- IPC is `status` / `remaining` / `cancel`;
- absolute argv everywhere;
- cancel verifies the unit, and every failure is shown to the user.

Do not reintroduce any of those patterns "for convenience".

## Repository / workflow

- Default branch: `main`.
- `main` is protected: changes land through a pull request, the CI `test` check
  must pass, force-pushes and deletions are blocked.
- Keep `README.md` user-facing and this file maintainer-facing.
- Run the Node tests before pushing; CI runs the same command.
