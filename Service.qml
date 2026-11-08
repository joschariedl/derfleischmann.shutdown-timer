import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless singleton (one instance for the whole shell, `keepLoaded: true`).
//
// It does not shut the machine down. It arms exactly one user-scoped systemd
// timer, then mirrors what systemd reports. The timer is the single trigger:
// there is no second code path that can power the machine off, so "Cancel"
// means "stop the timer", not "race the shell's countdown".
//
// Every command is a fixed argv array with an absolute program path. Nothing
// here reads a file, touches the network, or interpolates a string into a shell.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  // --- state mirrored from systemd ----------------------------------------
  property bool active: false
  property bool busy: false
  property bool expired: false
  property double deadlineMs: 0
  property int durationSec: 0
  property int remainingSec: 0
  property bool notifyEnabled: true
  property string lastError: ""
  property bool ready: false

  readonly property string remainingLabel: Model.formatRemaining(root.remainingSec)
  readonly property string durationLabel: Model.formatDuration(root.durationSec)
  readonly property bool urgent: root.active && root.remainingSec > 0 && root.remainingSec <= 60

  // --- private bookkeeping -------------------------------------------------
  property int opToken: 0
  property string opMode: ""        // "arm" | "cancel"
  property string opStep: ""
  property double pendingDeadline: 0
  property int pendingSeconds: 0
  property var warned: ({})
  property double expiredAt: 0
  property bool probing: false

  function log(message) {
    console.log("shutdown-timer: " + message)
  }

  // --- settings (one boolean, stored in shell.json) ------------------------

  function entrySettings() {
    if (!root.shell || !root.shell.barConfig || !root.shell.barConfig.layout) return null
    var layout = root.shell.barConfig.layout
    var sections = ["left", "centerBegin", "center", "centerEnd", "right", "tray"]
    for (var s = 0; s < sections.length; s++) {
      var entries = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (entry && String(entry.id || "") === Model.PLUGIN_ID) return entry
      }
    }
    return null
  }

  function syncSettings() {
    var entry = root.entrySettings()
    root.notifyEnabled = Model.notifyFrom(entry ? entry.notify : undefined)
  }

  function setNotifyEnabled(value) {
    root.notifyEnabled = value === true
    var entry = { id: Model.PLUGIN_ID }
    var current = root.entrySettings() || ({})
    for (var key in current) {
      if (key !== "id") entry[key] = current[key]
    }
    entry.notify = root.notifyEnabled
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(Model.PLUGIN_ID, entry)
  }

  // --- public API ----------------------------------------------------------

  function start(seconds) {
    var n = Model.clampSeconds(seconds)
    if (n <= 0) {
      root.lastError = "Choose a duration between 1 minute and 24 hours."
      return "invalid"
    }
    if (root.busy) return "busy"

    root.lastError = ""
    root.expired = false
    root.expiredAt = 0
    root.warned = ({})
    root.pendingSeconds = n
    root.pendingDeadline = Model.deadlineFromNow(n, Date.now())
    root.beginOp("arm")
    return "pending"
  }

  function cancel() {
    if (root.busy) return "busy"
    if (!root.active && !root.expired) return "idle"
    root.lastError = ""
    root.expired = false
    root.expiredAt = 0
    root.beginOp("cancel")
    return "pending"
  }

  function statusPayload() {
    return JSON.stringify({
      active: root.active,
      busy: root.busy,
      expired: root.expired,
      remainingSeconds: root.remainingSec,
      durationSeconds: root.durationSec,
      deadlineMs: root.deadlineMs,
      notifyEnabled: root.notifyEnabled,
      error: root.lastError
    })
  }

  // --- serialized systemd operations ---------------------------------------
  //
  // arm:    stop -> reset-failed -> systemd-run -> show (confirm armed)
  // cancel: stop -> reset-failed -> show (confirm not armed)
  //
  // Only stop/reset are shared; the confirmation step differs so a failed
  // cancel is reported instead of pretending success.

  function beginOp(mode) {
    root.opToken = root.opToken + 1
    root.opMode = mode
    root.busy = true
    root.runOp("stop")
  }

  function runOp(step) {
    var command = []
    if (step === "stop") command = Model.stopCommand()
    else if (step === "reset") command = Model.resetCommand()
    else if (step === "arm") command = Model.startCommand(root.pendingDeadline)
    else if (step === "show") command = Model.showCommand()

    if (command.length === 0) {
      root.failOp("Could not build a safe systemd command.")
      return
    }

    root.opStep = step
    opProc.token = root.opToken
    opProc.command = command
    if (opProc.running) opProc.running = false
    opProc.running = true
  }

  function handleOp(exitCode) {
    var stderrText = String(opErr.text || "").trim()

    if (root.opStep === "stop") {
      // A stop of a unit that was never loaded is expected to "fail"; the
      // reset below is what matters, and both outcomes are safe.
      root.runOp("reset")
      return
    }

    if (root.opStep === "reset") {
      if (root.opMode === "arm") root.runOp("arm")
      else root.runOp("show")
      return
    }

    if (root.opStep === "arm") {
      if (exitCode !== 0) {
        root.failOp("Could not arm the shutdown timer." + (stderrText ? " " + stderrText : ""))
        return
      }
      root.runOp("show")
      return
    }

    if (root.opStep === "show") {
      var parsed = Model.parseShowOutput(opOut.text)
      var armed = Model.isArmed(parsed) && Model.deadlineValid(parsed.deadlineMs, Date.now())

      if (root.opMode === "arm") {
        // If the timer is not armed with (roughly) the deadline we asked for,
        // nothing is scheduled and the user must be told. Never leave a timer
        // we cannot account for behind.
        if (!armed || Math.abs(parsed.deadlineMs - root.pendingDeadline) > 3000) {
          root.failOp("The shutdown timer did not stay armed, so nothing is scheduled.")
          return
        }
        root.adopt(parsed)
        root.finishOp()
        root.notify(Model.notifyStartCommand(root.durationLabel))
        return
      }

      if (armed) {
        root.failOp("Cancel did not stop the timer. A shutdown is still scheduled.")
        return
      }
      root.clear()
      root.finishOp()
      root.notify(Model.notifyCancelCommand())
    }
  }

  function finishOp() {
    root.busy = false
    root.opStep = ""
    root.opMode = ""
    root.ready = true
  }

  function failOp(message) {
    root.lastError = message
    root.log(message)
    if (root.opMode === "arm") root.discardStray()
    root.finishOp()
  }

  // Best-effort cleanup after a failed arm: make sure a half-armed timer does
  // not outlive the error message.
  function discardStray() {
    cleanupProc.command = Model.stopCommand()
    if (cleanupProc.running) cleanupProc.running = false
    cleanupProc.running = true
  }

  function adopt(parsed) {
    var now = Date.now()
    var started = parsed.startedMs > 0 ? parsed.startedMs : now
    var remaining = Model.remainingFromDeadline(parsed.deadlineMs, now)
    var duration = Math.round((parsed.deadlineMs - started) / 1000)
    if (!isFinite(duration) || duration <= 0) duration = root.pendingSeconds
    if (!isFinite(duration) || duration <= 0) duration = remaining
    root.durationSec = Model.clampSeconds(duration) || Math.max(Model.MIN_SECONDS, remaining)
    root.deadlineMs = parsed.deadlineMs
    root.remainingSec = remaining
    root.expired = false
    root.expiredAt = 0
    root.active = true
  }

  function clear() {
    root.active = false
    root.expired = false
    root.expiredAt = 0
    root.deadlineMs = 0
    root.durationSec = 0
    root.remainingSec = 0
  }

  function notify(command) {
    if (!root.notifyEnabled) return
    if (!command || command.length === 0) return
    Quickshell.execDetached(command)
  }

  // --- countdown -----------------------------------------------------------
  //
  // Pure display. When it reaches zero it does NOT call poweroff; systemd owns
  // the shutdown from the moment the timer was armed.

  function tick() {
    if (!root.active || root.busy) return

    var previous = root.remainingSec
    var remaining = Model.remainingFromDeadline(root.deadlineMs, Date.now())
    if (remaining === previous) return
    root.remainingSec = remaining

    var marks = Model.warningsFor(root.durationSec)
    for (var i = 0; i < marks.length; i++) {
      var mark = marks[i]
      if (root.warned[mark] === true) continue
      if (Model.shouldWarn(previous, remaining, mark)) {
        var next = {}
        for (var key in root.warned) next[key] = root.warned[key]
        next[mark] = true
        root.warned = next
        root.notify(Model.notifyWarningCommand(Model.formatRemaining(remaining)))
      }
    }

    if (remaining <= 0) {
      root.active = false
      root.expired = true
      root.expiredAt = Date.now()
    }
  }

  function checkExpired() {
    if (!root.expired) return
    if (Date.now() - root.expiredAt < 20000) return
    root.clear()
    root.lastError = "The countdown ended but this machine is still running. Check `systemctl --user status " + Model.UNIT + ".timer`."
    root.log(root.lastError)
  }

  // --- reconciliation with systemd -----------------------------------------

  function probe() {
    if (root.probing || root.busy) return
    root.probing = true
    probeProc.command = Model.showCommand()
    if (probeProc.running) probeProc.running = false
    probeProc.running = true
  }

  function handleProbe() {
    root.probing = false
    root.ready = true
    if (root.busy) return

    var parsed = Model.parseShowOutput(probeOut.text)
    var armed = Model.isArmed(parsed) && Model.deadlineValid(parsed.deadlineMs, Date.now())

    if (armed) {
      // The unit is the source of truth: after a shell restart, or an external
      // `systemctl stop`, follow what systemd says rather than our memory.
      root.adopt(parsed)
      return
    }

    if (root.active) {
      root.clear()
      root.lastError = "The systemd timer is gone, so no shutdown is scheduled."
      root.log(root.lastError)
    }
  }

  // --- IPC -----------------------------------------------------------------
  //
  // Deliberately read-only plus cancel. There is no remote `start`: a same-user
  // process should not be able to schedule a poweroff through this plugin. Use
  // the panel, which asks for confirmation.

  IpcHandler {
    target: Model.PLUGIN_ID

    function status(): string {
      return root.statusPayload()
    }

    function remaining(): int {
      return root.remainingSec
    }

    function cancel(): string {
      return root.cancel()
    }
  }

  Connections {
    target: root.shell
    function onBarConfigChanged() { root.syncSettings() }
  }

  Timer {
    interval: 500
    repeat: true
    running: root.active && !root.busy
    onTriggered: root.tick()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.expired
    onTriggered: root.checkExpired()
  }

  Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.probe()
  }

  Process {
    id: opProc
    property int token: 0
    stdout: StdioCollector { id: opOut; waitForEnd: true }
    stderr: StdioCollector { id: opErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (opProc.token !== root.opToken) return
      root.handleOp(exitCode)
    }
  }

  Process {
    id: probeProc
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function() { root.handleProbe() }
  }

  Process {
    id: cleanupProc
  }

  onShellChanged: root.syncSettings()

  Component.onCompleted: {
    root.syncSettings()
    root.probe()
  }

  Component.onDestruction: {
    // Leave the systemd timer armed. A shell restart must not cancel a
    // shutdown the user asked for; the next instance adopts the timer.
  }
}
