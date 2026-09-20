import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import "Model.js" as Model

// Owns the connection to the earbuds and everything derived from it.
//
// Sessions are short lived on purpose. Only one program may hold the Nothing
// RFCOMM control channel, so a resident daemon would make this widget a
// permanent contender for it and lock every other Nothing tool out. Opening,
// asking, and closing costs about a second and leaves the channel free.
Item {
  id: root

  property var settings: ({})

  property bool panelOpen: false

  property var status: Model.defaultStatus()
  property string lastError: ""
  property string actionError: ""
  property bool everLoaded: false

  readonly property string configuredAddress: String(setting("deviceAddress", "")).trim()
  readonly property int lowBatteryThreshold: intSetting("lowBatteryThreshold", 20, 5, 50)
  readonly property int keepaliveSec: intSetting("keepaliveSec", 60, 15, 600)
  readonly property bool notifyOnLowBattery: setting("notifyOnLowBattery", true) === true

  // Re-arm a low battery warning only once the level recovers this far past
  // the threshold, so a reading sitting on the line cannot flap.
  readonly property int lowBatteryResetMargin: 5
  readonly property int helperTimeoutSec: 12
  readonly property int settleHoldMs: 4000
  // A watch is bounded so a forgotten process cannot hold the control channel
  // for ever; it is restarted while the panel stays open.
  readonly property int watchSeconds: 870
  readonly property bool watching: watchProcess.running

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string helperPath: {
    var configured = String(setting("helperPath", "")).trim()
    return configured !== "" ? configured : pluginDir + "helper/nothing_ear.py"
  }

  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var device: findDevice()
  readonly property bool bluezConnected: device ? device.connected === true : false
  readonly property string address: {
    if (configuredAddress !== "") return configuredAddress
    return device && device.address ? String(device.address) : ""
  }
  readonly property bool deviceKnown: address !== ""

  readonly property bool protocol: status.protocol === true
  // An unverified device still gets battery and noise control -- those are the
  // same on every implementation surveyed. Equaliser and bass are withheld by
  // the helper rather than guessed, so their rows simply do not appear.
  readonly property bool modelKnown: status.model ? status.model.known === true : false
  readonly property string reportScript: pluginDir + "report-device.sh"

  function reportDevice() {
    // Runs in a terminal on purpose: the report is shown to the user, and
    // nothing is posted without them agreeing to it there.
    Quickshell.execDetached(["xdg-terminal-exec", "--", "bash", reportScript])
  }
  readonly property bool busy: statusProcess.running || actionProcess.running
  readonly property int barLevel: Model.lowestLevel(status)
  readonly property bool barLevelLow: barLevel !== Model.LEVEL_UNKNOWN
    && barLevel <= lowBatteryThreshold

  // Optimistic state. A click paints immediately and pins the field so a read
  // already in flight cannot snap it back to the old value. The pin expires
  // rather than waiting for a confirmation that may never come.
  property string pendingField: ""
  property string pendingValue: ""
  property string queuedCommand: ""
  property string queuedValue: ""

  property var lowLatched: ({})

  readonly property string ancMode: settleField("anc", status.anc.mode)
  readonly property string eqPreset: settleField("eq", status.eq.preset)

  signal notificationRequested(string title, string body)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function findDevice() {
    for (var i = 0; i < devices.length; i++) {
      var candidate = devices[i]
      if (!candidate) continue
      if (configuredAddress !== "") {
        if (String(candidate.address || "").toUpperCase() === configuredAddress.toUpperCase()) {
          return candidate
        }
        continue
      }
      var name = String(candidate.name || candidate.deviceName || "").toLowerCase()
      if (name.indexOf("nothing") >= 0 || name.indexOf("cmf") >= 0) return candidate
    }
    return null
  }

  function settleField(field, reported) {
    return pendingField === field ? pendingValue : reported
  }

  function clearPending() {
    pendingField = ""
    pendingValue = ""
    settleTimer.stop()
  }

  // Every helper call is wrapped in timeout(1). A wedged RFCOMM read must not
  // be able to leave a process running inside the shell for ever.
  function commandFor(args, timeoutSec) {
    var limit = timeoutSec === undefined ? helperTimeoutSec : timeoutSec
    var command = ["/usr/bin/timeout", String(limit), "/usr/bin/python3", helperPath]
    if (address !== "") command.push("--device", address)
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return command
  }

  function refresh() {
    if (!deviceKnown || !bluezConnected) return
    // A running watch already owns the channel and streams every change, so a
    // separate read would only collide with it.
    if (watching || statusProcess.running || actionProcess.running) return
    statusProcess.command = commandFor(["status"])
    statusProcess.running = true
  }

  // Live mode. The control channel is single-occupancy, so it is held only
  // while the panel is open: changes made on the earbuds themselves show up
  // at once for as long as someone is looking, and the channel is released
  // the moment the panel closes.
  function startWatch() {
    if (!deviceKnown || !bluezConnected || !panelOpen) return
    if (watchProcess.running || actionProcess.running) return
    watchProcess.command = commandFor(
      ["watch", "--seconds", String(watchSeconds)], watchSeconds + 10)
    watchProcess.running = true
  }

  function stopWatch() {
    if (watchProcess.running) watchProcess.running = false
  }

  function runAction(field, command, value) {
    if (!deviceKnown || !bluezConnected) return
    pendingField = field
    pendingValue = value
    settleTimer.restart()
    actionError = ""

    // The watch is holding the channel, and only one client may. Hand it over
    // rather than letting the action retry against a busy socket.
    stopWatch()

    if (actionProcess.running || statusProcess.running) {
      // Replace rather than drop: holding a key down produces a burst, and
      // only the last value in that burst is worth sending.
      queuedCommand = command
      queuedValue = value
      return
    }
    actionProcess.command = commandFor([command, value])
    actionProcess.running = true
  }

  function setAnc(mode) { runAction("anc", "set-anc", mode) }
  function setEq(preset) { runAction("eq", "set-eq", preset) }
  // Bass carries a level as well as a flag, so its pending value is the level
  // it was set to, or "off". Model.bassSelection reports in the same shape,
  // which is what lets the optimistic value settle against a real reading.
  readonly property int bassLevel: {
    if (pendingField === "bass" && pendingValue !== "off") {
      return Model.clampBassLevel(parseFloat(pendingValue))
    }
    return Model.clampBassLevel(Model.bassLevelOf(status))
  }

  function setBassLevel(level) {
    runAction("bass", "set-bass", String(Model.clampBassLevel(level)))
  }

  function setToggle(key, on) {
    if (key === "bass") {
      // Switching bass back on restores the level it had rather than
      // starting from zero.
      runAction("bass", "set-bass", on ? String(bassLevel) : "off")
      return
    }
    runAction(key, key === "latency" ? "set-latency" : "set-in-ear", on ? "on" : "off")
  }

  function toggleState(key) {
    // While a write is in flight the optimistic value wins, so the switch
    // moves under the finger rather than after the round trip.
    if (pendingField === key) return key === "bass" ? pendingValue !== "off" : pendingValue === "on"
    return status[key] ? status[key].enabled === true : false
  }
  function cycleAnc() { setAnc(Model.nextAncMode(ancMode)) }

  function applyOutput(text, isAction) {
    var parsed = Model.parseStatus(text)
    // A helper run that never reached the device must not erase a good
    // reading; keeping the last one spares the panel a full rebuild, which
    // moves every row out from under the pointer.
    if (!parsed.ok && !parsed.protocol && everLoaded && parsed.errorCode === "") return

    status = parsed
    everLoaded = true
    lastError = parsed.error
    if (isAction && parsed.errorCode !== "" && parsed.errorCode !== "busy") {
      actionError = parsed.error
    }

    if (pendingField !== "") {
      var reported = pendingField === "anc" ? parsed.anc.mode
        : pendingField === "eq" ? parsed.eq.preset
        : pendingField === "bass" ? Model.bassSelection(parsed)
        : (parsed[pendingField] && parsed[pendingField].enabled ? "on" : "off")
      if (reported === pendingValue) clearPending()
    }
    evaluateLowBattery(parsed)
  }

  function evaluateLowBattery(parsed) {
    if (!notifyOnLowBattery || !parsed.protocol) return
    var rows = Model.batteryRows(parsed)
    var latched = lowLatched
    var changed = false
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var wasNotified = latched[row.key] === true
      var decision = Model.lowBatteryDecision(
        row.pod, lowBatteryThreshold, lowBatteryResetMargin, wasNotified)
      if (decision.notified !== wasNotified) {
        latched[row.key] = decision.notified
        changed = true
      }
      if (decision.notify) {
        root.notificationRequested("Nothing Ear battery low",
                    row.label + " is at " + Model.levelText(row.pod.level))
      }
    }
    if (changed) lowLatched = latched
  }

  onBluezConnectedChanged: {
    if (!bluezConnected) {
      stopWatch()
      everLoaded = false
      status = Model.defaultStatus()
      clearPending()
      lowLatched = ({})
      return
    }
    // BlueZ reports the link up slightly before the control channel answers,
    // so the immediate attempt is backed by one deferred retry.
    refresh()
    retryTimer.restart()
  }

  onPanelOpenChanged: {
    if (panelOpen) startWatch()
    else stopWatch()
  }

  Component.onCompleted: if (bluezConnected) refresh()

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 124) {
        root.lastError = "The earbuds did not answer in time"
      } else {
        root.applyOutput(statusOut.text, false)
      }
      root.drainQueue()
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 124) {
        root.actionError = "The earbuds did not answer in time"
        root.clearPending()
      } else {
        root.applyOutput(actionOut.text, true)
      }
      root.drainQueue()
      root.startWatch()
    }
  }

  Process {
    id: watchProcess
    // One JSON object per line, emitted only when something actually changed.
    stdout: SplitParser {
      onRead: function (line) { root.applyOutput(line, false) }
    }
    onExited: {
      // The watch is bounded, so a clean exit while the panel is still open
      // just means the window elapsed; pick it straight back up.
      if (root.panelOpen && root.bluezConnected && !actionProcess.running) {
        watchRestart.restart()
      }
    }
  }

  Timer {
    id: watchRestart
    interval: 400
    onTriggered: root.startWatch()
  }

  function drainQueue() {
    if (queuedCommand === "") return
    var command = queuedCommand
    var value = queuedValue
    queuedCommand = ""
    queuedValue = ""
    actionProcess.command = commandFor([command, value])
    actionProcess.running = true
  }

  // Gives up on a pending value rather than pinning it for ever, then reads
  // back so the panel shows whatever the device actually settled on.
  Timer {
    id: settleTimer
    interval: root.settleHoldMs
    onTriggered: {
      root.clearPending()
      root.refresh()
    }
  }

  Timer {
    id: retryTimer
    interval: 1500
    onTriggered: if (root.bluezConnected && !root.protocol) root.refresh()
  }

  // The only recurring poll, and only while the panel is open. BlueZ cannot
  // see a noise mode changed by a pinch gesture or the phone, so an open
  // panel would otherwise drift. A closed panel costs nothing.
  Timer {
    // Fallback only. A live watch streams its own battery re-reads, so this
    // runs solely when the watch is not up.
    interval: root.keepaliveSec * 1000
    running: root.panelOpen && root.bluezConnected && !root.watching
    repeat: true
    onTriggered: root.refresh()
  }
}
