// Pure helpers for the Shutdown Timer plugin. Everything here is a function of
// its arguments, so the whole safety-critical surface can be unit tested with
// `node --test` outside QML.
//
// Safety rules encoded here:
//
//  * The shell never powers the machine off. It arms exactly one user-scoped
//    systemd timer; that timer is the single trigger. If this file is asked to
//    build anything other than "arm one timer" / "stop that timer", it returns
//    an empty command.
//  * Every program is an absolute path and every argument is either fixed or
//    derived from a bounded integer. No shell, no string interpolation, no PATH
//    lookup.
//  * Durations are integers inside [MIN_SECONDS, MAX_SECONDS]. Anything else is
//    rejected (0) instead of silently becoming a shorter, more surprising
//    timer.

var PLUGIN_ID = "derfleischmann.shutdown-timer"

// Fixed, unprivileged unit name. `--user` scope only: this plugin can never
// touch system units and needs no sudo/pkexec.
var UNIT = "derfleischmann-shutdown-timer"

var MIN_SECONDS = 60
var MAX_SECONDS = 86400

// Warning marks, largest first. Only marks strictly below the chosen duration
// are used, so a 1-minute timer does not warn "1 minute" the instant it starts.
var WARN_SECONDS = [600, 300, 60, 10]

// Absolute paths. Never resolve an executable through PATH.
var SYSTEMD_RUN = "/usr/bin/systemd-run"
var SYSTEMCTL = "/usr/bin/systemctl"
var SHUTDOWN_BIN = "/usr/share/omarchy/bin/omarchy-system"
var NOTIFY_BIN = "/usr/share/omarchy/bin/omarchy-notification-send"

function presets() {
  return [
    { id: "15m", label: "15 min", seconds: 15 * 60 },
    { id: "30m", label: "30 min", seconds: 30 * 60 },
    { id: "1h", label: "1 hour", seconds: 60 * 60 },
    { id: "2h", label: "2 hours", seconds: 2 * 60 * 60 }
  ]
}

function finiteNumber(value) {
  var n = Number(value)
  return isFinite(n) ? n : NaN
}

// Integer seconds in [MIN_SECONDS, MAX_SECONDS], or 0 when the input is not a
// usable duration. A value above MAX_SECONDS is capped; a value below the
// minimum is rejected rather than promoted to the minimum.
function clampSeconds(value) {
  var n = parseInt(String(value === undefined || value === null ? "" : value).trim(), 10)
  if (!isFinite(n)) return 0
  if (n < MIN_SECONDS) return 0
  if (n > MAX_SECONDS) return MAX_SECONDS
  return n
}

function minutesToSeconds(minutes) {
  var n = parseInt(String(minutes === undefined || minutes === null ? "" : minutes).trim(), 10)
  if (!isFinite(n) || n <= 0) return 0
  return clampSeconds(n * 60)
}

function secondsToMinutes(seconds) {
  var n = clampSeconds(seconds)
  return n > 0 ? Math.ceil(n / 60) : 0
}

function pad2(n) {
  var v = Math.max(0, Math.floor(n))
  return (v < 10 ? "0" : "") + String(v)
}

function formatRemaining(seconds) {
  var n = Math.max(0, Math.floor(Number(seconds) || 0))
  if (n < 60) return n + "s"
  var hours = Math.floor(n / 3600)
  var minutes = Math.floor((n % 3600) / 60)
  var secs = n % 60
  if (hours > 0) return hours + ":" + pad2(minutes) + ":" + pad2(secs)
  return minutes + ":" + pad2(secs)
}

function formatDuration(seconds) {
  var n = Math.max(0, Math.floor(Number(seconds) || 0))
  if (n <= 0) return "0 minutes"
  if (n < 60) return n === 1 ? "1 second" : n + " seconds"

  var hours = Math.floor(n / 3600)
  var minutes = Math.floor((n % 3600) / 60)
  var secs = n % 60
  var parts = []
  if (hours > 0) parts.push(hours === 1 ? "1 hour" : hours + " hours")
  if (minutes > 0) parts.push(minutes === 1 ? "1 minute" : minutes + " minutes")
  if (secs > 0 && hours === 0) parts.push(secs === 1 ? "1 second" : secs + " seconds")
  return parts.join(" ")
}

function deadlineFromNow(seconds, nowMs) {
  var n = clampSeconds(seconds)
  var now = finiteNumber(nowMs)
  if (n <= 0 || isNaN(now)) return 0
  return now + n * 1000
}

function remainingFromDeadline(deadlineMs, nowMs) {
  var deadline = finiteNumber(deadlineMs)
  var now = finiteNumber(nowMs)
  if (isNaN(deadline) || isNaN(now)) return 0
  return Math.max(0, Math.ceil((deadline - now) / 1000))
}

// A deadline we are willing to display and act on: positive, finite, and no
// further out than the maximum duration plus a small grace window. A past
// deadline is allowed (the timer may be firing right now).
function deadlineValid(deadlineMs, nowMs) {
  var deadline = finiteNumber(deadlineMs)
  var now = finiteNumber(nowMs)
  if (isNaN(deadline) || isNaN(now)) return false
  if (deadline <= 0) return false
  return deadline <= now + (MAX_SECONDS + 300) * 1000
}

function warningsFor(durationSeconds) {
  var n = clampSeconds(durationSeconds)
  var out = []
  if (n <= 0) return out
  for (var i = 0; i < WARN_SECONDS.length; i++) {
    if (WARN_SECONDS[i] < n) out.push(WARN_SECONDS[i])
  }
  return out
}

function shouldWarn(previousSeconds, currentSeconds, threshold) {
  var prev = finiteNumber(previousSeconds)
  var curr = finiteNumber(currentSeconds)
  var mark = finiteNumber(threshold)
  if (isNaN(prev) || isNaN(curr) || isNaN(mark)) return false
  if (mark <= 0 || curr <= 0) return false
  return prev > mark && curr <= mark
}

function presetIdForSeconds(seconds) {
  var n = clampSeconds(seconds)
  var list = presets()
  for (var i = 0; i < list.length; i++) {
    if (list[i].seconds === n) return list[i].id
  }
  return ""
}

function notifyFrom(value) {
  if (value === false || value === 0 || value === "0") return false
  if (typeof value === "string" && value.trim().toLowerCase() === "false") return false
  return true
}

// --- systemd -------------------------------------------------------------

// `systemctl show --timestamp=unix` prints timestamps as "@<epoch seconds>".
// Accept only that (or plain digits); anything else means "unknown", never a
// guessed date.
function timestampMs(value) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  if (text === "" || text === "n/a" || text === "0") return 0
  if (text.charAt(0) === "@") text = text.slice(1)
  if (!/^[0-9]+$/.test(text)) return 0
  var sec = Number(text)
  if (!isFinite(sec) || sec <= 0 || sec > 1000000000000) return 0
  return sec * 1000
}

// Parses the `Key=Value` output of Model.showCommand(). Returns the raw state
// plus two absolute timestamps in milliseconds (0 when unknown).
function parseShowOutput(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  var result = { state: "", deadlineMs: 0, startedMs: 0 }
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    var value = line.slice(eq + 1)
    if (key === "ActiveState") result.state = String(value).trim()
    else if (key === "NextElapseUSecRealtime") result.deadlineMs = timestampMs(value)
    else if (key === "ActiveEnterTimestamp") result.startedMs = timestampMs(value)
  }
  return result
}

function isArmed(parsed) {
  if (!parsed || typeof parsed !== "object") return false
  var state = String(parsed.state || "")
  if (state !== "active" && state !== "activating" && state !== "elapsing") return false
  return finiteNumber(parsed.deadlineMs) > 0 && !isNaN(finiteNumber(parsed.deadlineMs))
}

// Arms one wall-clock timer. Wall clock (not `--on-active`) is deliberate: the
// displayed countdown and systemd then agree across suspend/resume and after an
// NTP step, and a suspend cannot silently stretch the timer.
function startCommand(deadlineMs) {
  var deadline = finiteNumber(deadlineMs)
  if (isNaN(deadline) || deadline <= 0) return []
  var at = Math.floor(deadline / 1000)
  if (!isFinite(at) || at < 1) return []
  return [
    SYSTEMD_RUN,
    "--user",
    "--collect",
    "--quiet",
    "--unit=" + UNIT,
    "--on-calendar=@" + at,
    "--timer-property=AccuracySec=1s",
    SHUTDOWN_BIN,
    "shutdown"
  ]
}

function stopCommand() {
  return [SYSTEMCTL, "--user", "stop", UNIT + ".timer", UNIT + ".service"]
}

// Clears a failed/leftover transient unit so a later `systemd-run --unit=` can
// reuse the name. Failure is expected when the units do not exist and is
// ignored by the caller.
function resetCommand() {
  return [SYSTEMCTL, "--user", "reset-failed", UNIT + ".timer", UNIT + ".service"]
}

function showCommand() {
  return [
    SYSTEMCTL, "--user", "--timestamp=unix", "show", UNIT + ".timer",
    "--property=ActiveState,NextElapseUSecRealtime,ActiveEnterTimestamp"
  ]
}

// --- notifications (fixed text plus a formatted number) -------------------

function notifyStartCommand(durationLabel) {
  return [
    NOTIFY_BIN, "-g", "󰔟", "-u", "normal",
    "Shutdown scheduled",
    "This computer will shut down in " + String(durationLabel || "")
  ]
}

function notifyWarningCommand(remainingLabel) {
  return [
    NOTIFY_BIN, "-g", "󰐥", "-u", "critical",
    "Shutdown scheduled",
    "Shutting down in " + String(remainingLabel || "")
  ]
}

function notifyCancelCommand() {
  return [
    NOTIFY_BIN, "-g", "󰔛", "-u", "normal",
    "Shutdown cancelled",
    "The shutdown timer was cancelled"
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID,
    UNIT: UNIT,
    MIN_SECONDS: MIN_SECONDS,
    MAX_SECONDS: MAX_SECONDS,
    WARN_SECONDS: WARN_SECONDS,
    SYSTEMD_RUN: SYSTEMD_RUN,
    SYSTEMCTL: SYSTEMCTL,
    SHUTDOWN_BIN: SHUTDOWN_BIN,
    NOTIFY_BIN: NOTIFY_BIN,
    presets: presets,
    clampSeconds: clampSeconds,
    minutesToSeconds: minutesToSeconds,
    secondsToMinutes: secondsToMinutes,
    formatRemaining: formatRemaining,
    formatDuration: formatDuration,
    deadlineFromNow: deadlineFromNow,
    remainingFromDeadline: remainingFromDeadline,
    deadlineValid: deadlineValid,
    warningsFor: warningsFor,
    shouldWarn: shouldWarn,
    presetIdForSeconds: presetIdForSeconds,
    notifyFrom: notifyFrom,
    timestampMs: timestampMs,
    parseShowOutput: parseShowOutput,
    isArmed: isArmed,
    startCommand: startCommand,
    stopCommand: stopCommand,
    resetCommand: resetCommand,
    showCommand: showCommand,
    notifyStartCommand: notifyStartCommand,
    notifyWarningCommand: notifyWarningCommand,
    notifyCancelCommand: notifyCancelCommand
  }
}
