var LEVEL_UNKNOWN = -1

var GLYPH_CHECK = "\u{F012C}"

var CYCLE_MODES = ["off", "transparency", "high"]

var ANC_MODES = [
  { key: "off", label: "Off" },
  { key: "transparency", label: "Transparency" },
  { key: "adaptive", label: "Adaptive" },
  { key: "low", label: "Low" },
  { key: "mid", label: "Medium" },
  { key: "high", label: "High" }
]

var EQ_PRESETS = [
  { key: "balanced", label: "Balanced" },
  { key: "more_bass", label: "More bass" },
  { key: "more_treble", label: "More treble" },
  { key: "voice", label: "Voice" },
  { key: "dirac", label: "Dirac Opteo" },
  { key: "custom", label: "Custom" }
]

var BATTERY_ROWS = [
  { key: "left", label: "Left" },
  { key: "right", label: "Right" },
  { key: "case", label: "Case" }
]

function defaultPod() {
  return { level: LEVEL_UNKNOWN, charging: false, available: false, stale: false }
}

var TOGGLE_ROWS = [
  { key: "bass", label: "Bass enhance", caption: "Lifts the low end" },
  { key: "latency", label: "Low latency", caption: "Lower delay, shorter battery life" },
  { key: "inEar", label: "Wear detection", caption: "Pause when you take a bud out" }
]

var BASS_MIN_LEVEL = 1
var BASS_MAX_LEVEL = 5
var BASS_DEFAULT_LEVEL = 3

function defaultStatus() {
  return {
    ok: false,
    address: "",
    name: "",
    connected: false,
    paired: false,
    protocol: false,
    aggregateBattery: LEVEL_UNKNOWN,
    serial: "",
    firmware: "",
    battery: {},
    anc: { mode: "", level: null, available: false },
    eq: { preset: "", presets: [], available: false },
    bass: { enabled: false, level: null, available: false },
    model: { base: "unknown", name: "", known: false, support: "unknown" },
    latency: { enabled: false, available: false },
    inEar: { enabled: false, available: false },
    error: "",
    errorCode: ""
  }
}

function normalizePod(raw) {
  var pod = defaultPod()
  if (!raw || typeof raw !== "object") return pod
  var level = raw.level
  pod.level = typeof level === "number" && isFinite(level) ? level : LEVEL_UNKNOWN
  pod.available = raw.available === true && pod.level !== LEVEL_UNKNOWN
  pod.stale = raw.stale === true
  pod.charging = raw.charging === true && !pod.stale
  return pod
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    var failed = defaultStatus()
    failed.error = "Could not read the helper output"
    failed.errorCode = "parse"
    return failed
  }
  if (!parsed || typeof parsed !== "object") return defaultStatus()

  var status = defaultStatus()
  status.ok = parsed.ok === true
  status.address = String(parsed.address || "")
  status.name = String(parsed.name || "")
  status.connected = parsed.connected === true
  status.paired = parsed.paired === true
  status.protocol = parsed.protocol === true
  status.serial = String(parsed.serial || "")
  status.firmware = String(parsed.firmware || "")
  status.error = elideError(parsed.error)
  status.errorCode = String(parsed.errorCode || "")

  var aggregate = parsed.aggregateBattery
  status.aggregateBattery =
    typeof aggregate === "number" && aggregate >= 0 ? aggregate : LEVEL_UNKNOWN

  var battery = parsed.battery && typeof parsed.battery === "object" ? parsed.battery : {}
  for (var i = 0; i < BATTERY_ROWS.length; i++) {
    var key = BATTERY_ROWS[i].key
    status.battery[key] = normalizePod(battery[key])
  }

  var anc = parsed.anc && typeof parsed.anc === "object" ? parsed.anc : {}
  status.anc = {
    mode: isKnownAncMode(anc.mode) ? anc.mode : "",
    level: typeof anc.level === "number" ? anc.level : null,
    available: anc.available === true
  }

  var eq = parsed.eq && typeof parsed.eq === "object" ? parsed.eq : {}
  status.eq = {
    preset: isKnownEqPreset(eq.preset) ? eq.preset : "",
    presets: knownEqPresets(eq.presets),
    available: eq.available === true
  }

  var bass = parsed.bass && typeof parsed.bass === "object" ? parsed.bass : {}
  status.bass = {
    enabled: bass.enabled === true,
    level: typeof bass.level === "number" ? bass.level : null,
    available: bass.available === true
  }
  var model = parsed.model && typeof parsed.model === "object" ? parsed.model : {}
  status.model = {
    base: String(model.base || "unknown"),
    name: String(model.name || ""),
    known: model.known === true,
    support: ["unknown", "identified", "verified"].includes(String(model.support))
      ? String(model.support) : "unknown"
  }
  status.latency = normalizeToggle(parsed.latency)
  status.inEar = normalizeToggle(parsed.inEar)
  return status
}

function normalizeToggle(raw) {
  if (!raw || typeof raw !== "object") return { enabled: false, available: false }
  return { enabled: raw.enabled === true, available: raw.available === true }
}

function toggleRows(status) {
  var rows = []
  for (var i = 0; i < TOGGLE_ROWS.length; i++) {
    var row = TOGGLE_ROWS[i]
    var state = status ? status[row.key] : null
    if (!state || !state.available) continue
    rows.push({ key: row.key, label: row.label, caption: row.caption, enabled: state.enabled })
  }
  return rows
}

function isKnownAncMode(mode) {
  for (var i = 0; i < ANC_MODES.length; i++) {
    if (ANC_MODES[i].key === mode) return true
  }
  return false
}

function isKnownEqPreset(preset) {
  for (var i = 0; i < EQ_PRESETS.length; i++) {
    if (EQ_PRESETS[i].key === preset) return true
  }
  return false
}

// Only what the helper reports as mapped. Anything else would be a guess.
function knownEqPresets(presets) {
  var out = []
  if (!Array.isArray(presets)) return out
  for (var i = 0; i < presets.length; i++) {
    if (isKnownEqPreset(presets[i]) && out.indexOf(presets[i]) === -1) {
      out.push(presets[i])
    }
  }
  return out
}

// Rows in the order the panel lists them, limited to the confirmed presets.
function eqPresetsFor(status) {
  var names = status && status.eq ? status.eq.presets : null
  var out = []
  if (!names) return out
  for (var i = 0; i < EQ_PRESETS.length; i++) {
    if (names.indexOf(EQ_PRESETS[i].key) !== -1) out.push(EQ_PRESETS[i])
  }
  return out
}

function ancLabel(mode) {
  for (var i = 0; i < ANC_MODES.length; i++) {
    if (ANC_MODES[i].key === mode) return ANC_MODES[i].label
  }
  return "Unknown"
}

function eqLabel(preset) {
  for (var i = 0; i < EQ_PRESETS.length; i++) {
    if (EQ_PRESETS[i].key === preset) return EQ_PRESETS[i].label
  }
  return "Unknown"
}

function nextAncMode(current) {
  var index = CYCLE_MODES.indexOf(current)
  return CYCLE_MODES[(index + 1) % CYCLE_MODES.length]
}

function levelText(level) {
  return level === LEVEL_UNKNOWN || level === null ? "--" : String(level) + "%"
}

function levelFraction(level) {
  if (level === LEVEL_UNKNOWN || level === null) return 0
  return Math.max(0, Math.min(100, level)) / 100
}

function podMeta(pod) {
  if (!pod || !pod.available) return ""
  if (pod.charging) return "Charging"
  if (pod.stale) return "Last seen"
  return ""
}

function isLow(pod, threshold) {
  if (!pod || !pod.available || pod.charging) return false
  return pod.level !== LEVEL_UNKNOWN && pod.level <= threshold
}

function batteryRows(status) {
  var rows = []
  for (var i = 0; i < BATTERY_ROWS.length; i++) {
    var row = BATTERY_ROWS[i]
    rows.push({
      key: row.key,
      label: row.label,
      pod: (status && status.battery && status.battery[row.key]) || defaultPod()
    })
  }
  return rows
}

function lowestLevel(status) {
  // Only the earbuds count. The case is charging them, so folding it in would
  // make the bar read empty every time the buds are put away full.
  var lowest = LEVEL_UNKNOWN
  var keys = ["left", "right"]
  for (var i = 0; i < keys.length; i++) {
    var pod = status && status.battery ? status.battery[keys[i]] : null
    if (!pod || !pod.available || pod.level === LEVEL_UNKNOWN) continue
    if (lowest === LEVEL_UNKNOWN || pod.level < lowest) lowest = pod.level
  }
  if (lowest === LEVEL_UNKNOWN && status && status.aggregateBattery >= 0) {
    return status.aggregateBattery
  }
  return lowest
}

function elideError(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 140 ? value.slice(0, 139) + "…" : value
}

// Low-battery latch.
//
// Pure so the hysteresis is testable: a level sitting on the threshold must
// not produce a notification on every refresh. Trips once at or below the
// threshold, and only re-arms once the level recovers past a margin or the
// pod goes on charge.
function lowBatteryDecision(pod, threshold, resetMargin, notified) {
  var quiet = { notify: false, notified: notified }
  if (!pod || !pod.available || pod.level === LEVEL_UNKNOWN) return quiet
  if (pod.stale) return quiet
  if (pod.charging) return { notify: false, notified: false }
  if (pod.level <= threshold) {
    return notified ? quiet : { notify: true, notified: true }
  }
  if (pod.level >= threshold + resetMargin) return { notify: false, notified: false }
  return quiet
}


// Which bass row is selected. A half-step level the panel cannot express
// matches nothing, which shows as no selection rather than a wrong one.
function bassSelection(status) {
  if (!status || !status.bass || !status.bass.available) return ""
  if (!status.bass.enabled) return "off"
  if (status.bass.level === null) return ""
  return String(status.bass.level)
}


// The level to show on the slider, and the one to restore when bass is
// switched back on. A device reporting 0 has no useful level to go back to,
// so the default stands in.
function bassLevelOf(status) {
  var level = status && status.bass ? status.bass.level : null
  if (typeof level !== "number" || level < BASS_MIN_LEVEL) return BASS_DEFAULT_LEVEL
  return Math.min(BASS_MAX_LEVEL, level)
}

// Slider positions are whole steps even though the wire allows halves, so a
// value read back from the device is snapped before it is shown.
function clampBassLevel(level) {
  var n = Math.round(level)
  if (!isFinite(n) || n < BASS_MIN_LEVEL) return BASS_MIN_LEVEL
  return n > BASS_MAX_LEVEL ? BASS_MAX_LEVEL : n
}
