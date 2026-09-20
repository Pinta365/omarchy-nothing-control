// Tests for Model.js.
//
// Model.js is loaded as a plain script rather than imported, because QML's
// `import "Model.js" as Model` needs a file with no export statements. The
// Function wrapper gives us the same top-level bindings QML would see.

import { assert, assertEquals } from "jsr:@std/assert@1"

const source = await Deno.readTextFile(new URL("../Model.js", import.meta.url))
const Model = new Function(`
  ${source}
  return {
    LEVEL_UNKNOWN, parseStatus, defaultStatus, defaultPod, normalizePod,
    ancLabel, eqLabel, eqPresetsFor, nextAncMode, levelText, levelFraction, podMeta,
    isLow, batteryRows, lowestLevel, elideError
  }
`)() as Record<string, any>

const UNKNOWN = Model.LEVEL_UNKNOWN

function statusJson(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    ok: true,
    address: "2C:BE:EE:87:AD:E8",
    connected: true,
    protocol: true,
    battery: {
      left: { level: 90, charging: false, available: true, stale: false },
      right: { level: 85, charging: true, available: true, stale: false },
      case: { level: 60, charging: false, available: true, stale: false },
    },
    anc: { mode: "transparency", level: 3, available: true },
    eq: { preset: "balanced", available: true },
    ...overrides,
  })
}

Deno.test("empty helper output produces a safe default", () => {
  const status = Model.parseStatus("")
  assertEquals(status.ok, false)
  assertEquals(status.protocol, false)
  assertEquals(Model.lowestLevel(status), UNKNOWN)
})

Deno.test("non-JSON output is surfaced as a parse error", () => {
  const status = Model.parseStatus("Traceback (most recent call last):")
  assertEquals(status.errorCode, "parse")
  assert(status.error.length > 0)
})

Deno.test("truncated JSON does not crash parsing", () => {
  const status = Model.parseStatus('{"ok":true,"battery":')
  assertEquals(status.errorCode, "parse")
})

Deno.test("a complete status parses every field", () => {
  const status = Model.parseStatus(statusJson())
  assertEquals(status.ok, true)
  assertEquals(status.battery.left.level, 90)
  assertEquals(status.battery.right.charging, true)
  assertEquals(status.anc.mode, "transparency")
  assertEquals(status.eq.preset, "balanced")
})

Deno.test("model support state is preserved only for known states", () => {
  assertEquals(Model.parseStatus(statusJson({
    model: { base: "B999", name: "Example", known: true, support: "identified" },
  })).model.support, "identified")
  assertEquals(Model.parseStatus(statusJson({
    model: { base: "B999", name: "Example", known: true, support: "pending" },
  })).model.support, "unknown")
})

Deno.test("only the presets the helper confirms are offered", () => {
  const status = Model.parseStatus(statusJson({
    eq: { preset: "balanced", presets: ["more_bass", "balanced"], available: true },
  }))
  assertEquals(status.eq.presets, ["more_bass", "balanced"])
  assertEquals(Model.eqPresetsFor(status).map((row: any) => row.key),
    ["balanced", "more_bass"])
})

Deno.test("a preset the device named itself is offered and labelled", () => {
  const status = Model.parseStatus(statusJson({
    eq: { preset: "super_bass", presets: ["balanced", "super_bass"], available: true },
  }))
  assertEquals(status.eq.presets, ["balanced", "super_bass"])
  assertEquals(Model.eqPresetsFor(status).map((row: any) => [row.key, row.label]),
    [["balanced", "Balanced"], ["super_bass", "Super bass"]])
  assertEquals(status.eq.preset, "super_bass", "the selected chip still matches")
})

Deno.test("the app's own label is used when the device supplied one", () => {
  const status = Model.parseStatus(statusJson({
    eq: {
      preset: "cmf_signature",
      presets: ["balanced", "cmf_signature"],
      presetLabels: { cmf_signature: "CMF Signature", balanced: "Standard" },
      available: true,
    },
  }))
  // A confirmed label wins over ours, including for a name we ship.
  assertEquals(Model.eqPresetsFor(status).map((row: any) => row.label),
    ["Standard", "CMF Signature"])
})

Deno.test("unusable labels fall back rather than rendering junk", () => {
  const status = Model.parseStatus(statusJson({
    eq: {
      preset: "balanced",
      presets: ["balanced", "super_bass"],
      presetLabels: { balanced: "   ", super_bass: 7, ghost: "Not a preset" },
      available: true,
    },
  }))
  assertEquals(status.eq.presetLabels, {})
  assertEquals(Model.eqPresetsFor(status).map((row: any) => row.label),
    ["Balanced", "Super bass"])

  const messy = Model.parseStatus(statusJson({
    eq: {
      preset: "super_bass",
      presets: ["super_bass"],
      presetLabels: { super_bass: "  Deep\n\tBass " + "x".repeat(60) + "  " },
      available: true,
    },
  }))
  const label = Model.eqPresetsFor(messy)[0].label
  assertEquals(label.length, 32)
  assertEquals(label.startsWith("Deep Bass x"), true)
})

Deno.test("malformed or missing preset names are dropped", () => {
  // Shape only; "unknown" is the helper's sentinel for an id it could not name.
  assertEquals(Model.parseStatus(statusJson({
    eq: {
      preset: "balanced",
      presets: ["balanced", "More Bass", "has space", "x".repeat(33), "", "unknown", 7, null,
                "balanced"],
      available: true,
    },
  })).eq.presets, ["balanced"])

  const absent = Model.parseStatus(statusJson({
    eq: { preset: "balanced", available: true },
  }))
  assertEquals(absent.eq.presets, [])
  assertEquals(Model.eqPresetsFor(absent), [])

  for (const presets of ["balanced", 3, {}, null]) {
    assertEquals(Model.parseStatus(statusJson({
      eq: { preset: "balanced", presets, available: true },
    })).eq.presets, [])
  }
})

Deno.test("missing case data is treated as unknown, not zero", () => {
  const status = Model.parseStatus(statusJson({
    battery: { left: { level: 90, available: true } },
  }))
  assertEquals(status.battery.case.level, UNKNOWN)
  assertEquals(status.battery.case.available, false)
  assertEquals(Model.levelText(status.battery.case.level), "--")
})

Deno.test("available:false is handled the same as an absent field", () => {
  const pod = Model.normalizePod({ level: 55, available: false })
  assertEquals(pod.available, false)
})

Deno.test("stale readings are never rendered as charging", () => {
  const pod = Model.normalizePod({ level: 60, charging: true, available: true, stale: true })
  assertEquals(pod.charging, false)
  assertEquals(Model.podMeta(pod), "Last seen")
})

Deno.test("charging captions take precedence over other states", () => {
  const pod = Model.normalizePod({ level: 60, charging: true, available: true })
  assertEquals(Model.podMeta(pod), "Charging")
})

Deno.test("unknown ANC values are not displayed as selected modes", () => {
  const status = Model.parseStatus(statusJson({
    anc: { mode: "hyperdrive", available: true },
  }))
  assertEquals(status.anc.mode, "")
  assertEquals(Model.ancLabel("hyperdrive"), "Unknown")
})

Deno.test("the ANC cycle wraps correctly and tolerates off-cycle modes", () => {
  assertEquals(Model.nextAncMode("off"), "transparency")
  assertEquals(Model.nextAncMode("transparency"), "high")
  assertEquals(Model.nextAncMode("high"), "off")
  // "adaptive" is a real mode but not part of the cycle; it must step to the
  // first entry rather than land on index -1 + 1 == 0 by accident.
  assertEquals(Model.nextAncMode("adaptive"), "off")
  assertEquals(Model.nextAncMode(""), "off")
})

Deno.test("bar level excludes the charging case", () => {
  const status = Model.parseStatus(statusJson({
    battery: {
      left: { level: 90, available: true },
      right: { level: 85, available: true },
      case: { level: 5, available: true },
    },
  }))
  assertEquals(Model.lowestLevel(status), 85)
})

Deno.test("bar level falls back to the BlueZ aggregate when the control channel is busy", () => {
  const status = Model.parseStatus(JSON.stringify({
    ok: true, connected: true, protocol: false,
    aggregateBattery: 70, errorCode: "busy", error: "Control channel busy",
  }))
  assertEquals(status.protocol, false)
  assertEquals(Model.lowestLevel(status), 70)
})

Deno.test("levels are formatted safely and clamped", () => {
  assertEquals(Model.levelText(UNKNOWN), "--")
  assertEquals(Model.levelText(0), "0%")
  assertEquals(Model.levelFraction(UNKNOWN), 0)
  assertEquals(Model.levelFraction(150), 1)
  assertEquals(Model.levelFraction(-5), 0)
})

Deno.test("low-battery checks ignore charging and unknown pods", () => {
  assertEquals(Model.isLow({ level: 10, available: true, charging: false }, 20), true)
  assertEquals(Model.isLow({ level: 10, available: true, charging: true }, 20), false)
  assertEquals(Model.isLow({ level: UNKNOWN, available: false }, 20), false)
})

Deno.test("battery rows include the case entry", () => {
  const rows = Model.batteryRows(Model.parseStatus(""))
  assertEquals(rows.some((r: any) => r.key === "case"), true)
})

Deno.test("error text is collapsed to a single line", () => {
  assertEquals(Model.elideError("  a\n\n  b  "), "a b")
})

const Latch = new Function(`
  ${source}
  return { lowBatteryDecision }
`)() as Record<string, any>

function pod(level: number, extra: Record<string, unknown> = {}) {
  return { level, available: true, charging: false, stale: false, ...extra }
}

Deno.test("low-battery notifications trigger once per threshold crossing", () => {
  let notified = false
  let r = Latch.lowBatteryDecision(pod(18), 20, 5, notified)
  assertEquals(r.notify, true)
  notified = r.notified

  r = Latch.lowBatteryDecision(pod(17), 20, 5, notified)
  assertEquals(r.notify, false)

  r = Latch.lowBatteryDecision(pod(20), 20, 5, r.notified)
  assertEquals(r.notify, false)
  assertEquals(r.notified, true)
})

Deno.test("low-battery state re-arms only past the reset margin", () => {
  let r = Latch.lowBatteryDecision(pod(24), 20, 5, true)
  assertEquals(r.notified, true, "24 is inside the margin, stay latched")
  r = Latch.lowBatteryDecision(pod(25), 20, 5, true)
  assertEquals(r.notified, false, "25 clears the margin, re-arm")
  assertEquals(r.notify, false, "re-arming is not itself a notification")
})

Deno.test("charging clears the low-battery latch without notifying", () => {
  const r = Latch.lowBatteryDecision(pod(5, { charging: true }), 20, 5, true)
  assertEquals(r.notify, false)
  assertEquals(r.notified, false)
})

Deno.test("stale or unknown readings never trigger notifications", () => {
  assertEquals(Latch.lowBatteryDecision(pod(5, { stale: true }), 20, 5, false).notify, false)
  assertEquals(Latch.lowBatteryDecision(pod(UNKNOWN, { available: false }), 20, 5, false).notify, false)
})
