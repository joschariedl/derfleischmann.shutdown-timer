# Shutdown Timer

[![CI](https://github.com/joschariedl/derfleischmann.shutdown-timer/actions/workflows/test.yml/badge.svg)](https://github.com/joschariedl/derfleischmann.shutdown-timer/actions/workflows/test.yml)

An Omarchy 4 (Quattro) bar plugin that shuts the machine down after a
countdown — built so that the countdown, the cancel button, and the actual
poweroff cannot disagree.

## Design: one trigger, verified

Most "shutdown timer" plugins arm a systemd timer **and** keep their own
countdown, then call `poweroff` from the shell when it reaches zero. That gives
two independent triggers and a race: a cancel in the last second can lose.

This plugin has exactly one trigger:

1. The shell arms **one** user-scoped transient systemd timer with a wall-clock
   deadline (`systemd-run --user --on-calendar=@<epoch>`).
2. The shell's countdown is a pure view over that timer. When it reaches zero it
   does nothing — systemd runs `/usr/share/omarchy/bin/omarchy-system shutdown`
   (the stock Omarchy shutdown path: close windows, then `systemctl poweroff`).
3. "Cancel" stops the timer, then **re-reads the unit** and only reports success
   if it is really no longer armed. A failed cancel is shown as an error, not as
   a false success.
4. On shell restart the state is not restored from a file — it is re-read from
   `systemctl --user show`. If the unit is not armed, no shutdown is scheduled.

Wall-clock scheduling (instead of `--on-active`) keeps the displayed countdown
and systemd in agreement across suspend/resume and NTP steps.

## Safety properties

- **No sudo, no pkexec, no system units.** Everything is `--user` scope and
  runs as you. The final poweroff is the stock Omarchy path, which works for an
  active local session without elevation.
- **No shell.** Every command is a fixed argv array with an absolute program
  path (`/usr/bin/systemd-run`, `/usr/bin/systemctl`,
  `/usr/share/omarchy/bin/omarchy-system`). No `sh -c`, no string
  interpolation, no `PATH` lookup.
- **No file state to poison.** There is no state file, so nothing under
  `$XDG_RUNTIME_DIR`/`$XDG_STATE_HOME` can be replaced to change what the timer
  does. The systemd unit is the single source of truth.
- **No network.** The plugin never opens a socket or fetches anything.
- **No remote start.** The IPC target exposes `status`, `remaining`, and
  `cancel` only. A same-user process cannot schedule a poweroff through this
  plugin; the panel asks for confirmation.
- **Confirm before scheduling.** Picking a preset or a custom duration opens a
  confirmation dialog that defaults to **Cancel**.
- **Cancel never asks twice.** Right-clicking the bar icon (or the panel button)
  cancels immediately — stopping a shutdown is the safe direction.
- **Disaster check.** If the systemd timer disappears mid-countdown, the panel
  says so instead of continuing to count down to nothing.
- `Text.PlainText` everywhere, so no notification or label can be interpreted as
  markup.

## Install

```bash
omarchy plugin validate .
omarchy plugin add "$PWD" --enable
# or, when developing locally:
mkdir -p ~/.config/omarchy/plugins/derfleischmann.shutdown-timer
cp manifest.json Model.js Service.qml BarWidget.qml ~/.config/omarchy/plugins/derfleischmann.shutdown-timer/
omarchy plugin enable derfleischmann.shutdown-timer --section right
```

After copying files, reload the shell:

```bash
omarchy restart shell
```

Omarchy launches the shell with `QS_DISABLE_FILE_WATCHER=1`; a live shell can
keep compiling a cached copy after you edit a plugin file. A restart is the
reliable way to pick up changes. `omarchy-shell shell rescanPlugins` is worth a
try first, but do not trust it after changing a file's imports.

## Use

Left-click the timer icon: pick a preset (15 min, 30 min, 1 hour, 2 hours) or a
custom number of minutes, confirm, done. The bar shows the remaining time.

- **Cancel:** the panel's "Cancel shutdown" button, or right-click the bar icon.
- **Notifications** are on by default (start, 10/5/1 minute warnings, cancel);
  toggle them in the panel.

From a terminal (read-only plus cancel):

```bash
omarchy-shell derfleischmann.shutdown-timer status
omarchy-shell derfleischmann.shutdown-timer remaining
omarchy-shell derfleischmann.shutdown-timer cancel
omarchy-shell derfleischmann.shutdown-timer.panel toggle
```

Inspect the timer directly:

```bash
systemctl --user list-timers derfleischmann-shutdown-timer.timer
systemctl --user status derfleischmann-shutdown-timer.timer
```

## Requirements

- Omarchy 4 (Quickshell shell).
- systemd with `systemctl --timestamp=unix` (systemd 254+; Omarchy 4 ships far
  newer).

## Disable / uninstall

```bash
omarchy plugin disable derfleischmann.shutdown-timer
omarchy plugin remove derfleischmann.shutdown-timer
```

Removing the plugin leaves an armed timer alone on purpose — never silently
cancel a shutdown the user asked for. Stop it explicitly if you want to:

```bash
systemctl --user stop derfleischmann-shutdown-timer.timer
```

## Validate from source

```bash
omarchy plugin validate .
node --test tests/model.test.js
```

## License

MIT.
