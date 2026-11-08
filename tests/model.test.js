const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("durations are bounded integers, not silently shortened", () => {
  assert.equal(Model.clampSeconds(60), 60)
  assert.equal(Model.clampSeconds("90"), 90)
  assert.equal(Model.clampSeconds(86400), 86400)
  assert.equal(Model.clampSeconds(86401), 86400)
  assert.equal(Model.clampSeconds(59), 0)
  assert.equal(Model.clampSeconds(0), 0)
  assert.equal(Model.clampSeconds(-5), 0)
  assert.equal(Model.clampSeconds(""), 0)
  assert.equal(Model.clampSeconds("abc"), 0)
  assert.equal(Model.clampSeconds(null), 0)
  assert.equal(Model.clampSeconds(undefined), 0)
  assert.equal(Model.clampSeconds(Infinity), 0)
})

test("minutes convert into a safe duration", () => {
  assert.equal(Model.minutesToSeconds(1), 60)
  assert.equal(Model.minutesToSeconds(60), 3600)
  assert.equal(Model.minutesToSeconds(1440), 86400)
  assert.equal(Model.minutesToSeconds(1441), 86400)
  assert.equal(Model.minutesToSeconds(0), 0)
  assert.equal(Model.minutesToSeconds(-1), 0)
  assert.equal(Model.secondsToMinutes(3600), 60)
  assert.equal(Model.secondsToMinutes(90), 2)
})

test("labels are plain text built from numbers", () => {
  assert.equal(Model.formatRemaining(0), "0s")
  assert.equal(Model.formatRemaining(9), "9s")
  assert.equal(Model.formatRemaining(90), "1:30")
  assert.equal(Model.formatRemaining(3600), "1:00:00")
  assert.equal(Model.formatDuration(60), "1 minute")
  assert.equal(Model.formatDuration(3600), "1 hour")
  assert.equal(Model.formatDuration(5400), "1 hour 30 minutes")
  assert.equal(Model.formatDuration(86400), "24 hours")
})

test("deadline math stays finite", () => {
  const now = 1_000_000
  assert.equal(Model.deadlineFromNow(90, now), now + 90_000)
  assert.equal(Model.deadlineFromNow(0, now), 0)
  assert.equal(Model.remainingFromDeadline(now + 1500, now), 2)
  assert.equal(Model.remainingFromDeadline(now - 1, now), 0)
  assert.equal(Model.remainingFromDeadline(Infinity, now), 0)
  assert.equal(Model.remainingFromDeadline(now, NaN), 0)
})

test("only sane deadlines are accepted", () => {
  const now = 1_000_000
  assert.equal(Model.deadlineValid(now + 60_000, now), true)
  assert.equal(Model.deadlineValid(now - 60_000, now), true) // may be firing now
  assert.equal(Model.deadlineValid(now + (Model.MAX_SECONDS + 300) * 1000, now), true)
  assert.equal(Model.deadlineValid(now + (Model.MAX_SECONDS + 301) * 1000, now), false)
  assert.equal(Model.deadlineValid(Infinity, now), false)
  assert.equal(Model.deadlineValid(0, now), false)
  assert.equal(Model.deadlineValid(-1, now), false)
  assert.equal(Model.deadlineValid("1e400", now), false)
})

test("warnings are only scheduled for marks below the chosen duration", () => {
  assert.deepEqual(Model.warningsFor(60), [10])
  assert.deepEqual(Model.warningsFor(10), [])
  assert.deepEqual(Model.warningsFor(600), [300, 60, 10])
  assert.deepEqual(Model.warningsFor(900), [600, 300, 60, 10])
  assert.deepEqual(Model.warningsFor(0), [])
  assert.equal(Model.shouldWarn(601, 600, 600), true)
  assert.equal(Model.shouldWarn(600, 599, 600), false)
  assert.equal(Model.shouldWarn(11, 10, 10), true)
  assert.equal(Model.shouldWarn(5, 4, 10), false)
})

test("systemd output is parsed without guessing timestamps", () => {
  const shown = [
    "ActiveState=active",
    "NextElapseUSecRealtime=@1794157408",
    "ActiveEnterTimestamp=@1794156808"
  ].join("\n")
  const parsed = Model.parseShowOutput(shown)
  assert.equal(parsed.state, "active")
  assert.equal(parsed.deadlineMs, 1794157408 * 1000)
  assert.equal(parsed.startedMs, 1794156808 * 1000)
  assert.equal(Model.isArmed(parsed), true)

  assert.equal(Model.isArmed(Model.parseShowOutput("ActiveState=inactive")), false)
  assert.equal(Model.isArmed(Model.parseShowOutput("")), false)
  // A localized human date is not a number: refuse it instead of guessing.
  assert.equal(Model.timestampMs("Sun 2026-11-08 18:03:28 CET"), 0)
  assert.equal(Model.timestampMs("@"), 0)
  assert.equal(Model.timestampMs("@1e400"), 0)
  assert.equal(Model.timestampMs("@999999999999999999"), 0)
  assert.equal(Model.timestampMs("n/a"), 0)
})

test("arming uses one absolute-path argv with a bounded integer", () => {
  const deadline = 1794157408000
  const command = Model.startCommand(deadline)
  assert.deepEqual(command, [
    "/usr/bin/systemd-run",
    "--user",
    "--collect",
    "--quiet",
    "--unit=derfleischmann-shutdown-timer",
    "--on-calendar=@1794157408",
    "--timer-property=AccuracySec=1s",
    "/usr/share/omarchy/bin/omarchy-system",
    "shutdown"
  ])
  assert.ok(command.every((arg) => typeof arg === "string"))
  assert.match(command[5], /^--on-calendar=@[0-9]+$/)
  assert.equal(command.includes("-i"), false)
  assert.equal(command.includes("poweroff"), false)
  assert.equal(command.includes("--force"), false)
  assert.equal(command.includes("sudo"), false)
})

test("invalid deadlines produce no command at all", () => {
  assert.deepEqual(Model.startCommand(0), [])
  assert.deepEqual(Model.startCommand(-1), [])
  assert.deepEqual(Model.startCommand(NaN), [])
  assert.deepEqual(Model.startCommand(Infinity), [])
  assert.deepEqual(Model.startCommand("1e400"), [])
  assert.deepEqual(Model.startCommand(null), [])
})

test("stop and show are fixed user-scope argv", () => {
  assert.deepEqual(Model.stopCommand(), [
    "/usr/bin/systemctl", "--user", "stop",
    "derfleischmann-shutdown-timer.timer",
    "derfleischmann-shutdown-timer.service"
  ])
  assert.deepEqual(Model.resetCommand(), [
    "/usr/bin/systemctl", "--user", "reset-failed",
    "derfleischmann-shutdown-timer.timer",
    "derfleischmann-shutdown-timer.service"
  ])
  assert.deepEqual(Model.showCommand(), [
    "/usr/bin/systemctl", "--user", "--timestamp=unix", "show",
    "derfleischmann-shutdown-timer.timer",
    "--property=ActiveState,NextElapseUSecRealtime,ActiveEnterTimestamp"
  ])
  for (const command of [Model.stopCommand(), Model.resetCommand(), Model.showCommand()]) {
    assert.equal(command[1], "--user")
    assert.equal(command.includes("--system"), false)
    assert.equal(command.some((arg) => /sudo|pkexec|sh -c/.test(arg)), false)
  }
})

test("notifications use fixed argv and an absolute binary", () => {
  const commands = [
    Model.notifyStartCommand("1 hour"),
    Model.notifyWarningCommand("1:00"),
    Model.notifyCancelCommand()
  ]
  for (const command of commands) {
    assert.equal(command[0], "/usr/share/omarchy/bin/omarchy-notification-send")
    assert.ok(command.every((arg) => typeof arg === "string"))
    assert.equal(command.some((arg) => /[;&|`$]/.test(arg) && arg !== "󰐥"), false)
  }
  assert.equal(Model.notifyStartCommand("1 hour").includes("This computer will shut down in 1 hour"), true)
  assert.equal(Model.notifyCancelCommand().includes("The shutdown timer was cancelled"), true)
})

test("the notification setting defaults on and only an explicit false disables it", () => {
  assert.equal(Model.notifyFrom(undefined), true)
  assert.equal(Model.notifyFrom(null), true)
  assert.equal(Model.notifyFrom(true), true)
  assert.equal(Model.notifyFrom(false), false)
  assert.equal(Model.notifyFrom("false"), false)
  assert.equal(Model.notifyFrom("0"), false)
  assert.equal(Model.notifyFrom(0), false)
})

test("presets are the expected four durations and all valid", () => {
  assert.deepEqual(Model.presets().map((p) => p.seconds), [900, 1800, 3600, 7200])
  for (const preset of Model.presets()) {
    assert.equal(Model.clampSeconds(preset.seconds), preset.seconds)
  }
  assert.equal(Model.presetIdForSeconds(3600), "1h")
  assert.equal(Model.presetIdForSeconds(61), "")
})
