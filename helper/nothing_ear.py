#!/usr/bin/env python3
"""Nothing Ear (a) control helper.

Speaks the Nothing X RFCOMM protocol directly and prints one JSON object on
stdout. Standard library only, so the plugin needs no install step.

Must be run with /usr/bin/python3, not whatever `python3` resolves to: version
managers (mise, pyenv, asdf) generally build CPython without Bluetooth socket
support, and `socket.BTPROTO_RFCOMM` is simply absent there.
"""

import argparse
import errno
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time

# Nothing's vendor control channel. The device also advertises Serial Port
# (0x1101), which is a different service and will not answer these frames.
CONTROL_UUID = "aeac4a03-dff5-498f-843a-34487cf133eb"
RFCOMM_CHANNEL = 15

SOF = 0x55
# The control word is three fields, not a magic number:
#   0x0F00  device type  -- 1 is a TWS headset, which is what 0x0100 encodes
#   0x40    this frame carries a sequence number
#   0x20    a CRC trailer follows
# So 0x0160 is "TWS headset, sequenced, CRC present". Incoming frames may set
# these differently, which is why the CRC bit is tested per frame rather than
# assumed -- pushed event frames use 0x0100 and carry no CRC.
CTRL_WITH_CRC = 0x0160
CRC_PRESENT_BIT = 0x20
CTRL_DEVICE_TYPE_MASK = 0x0F00
HEADER_SIZE = 8

DIR_GET = 0xC0
DIR_SET = 0xF0
DIR_RESPONSE = 0x40
DIR_ACK = 0x70
# The earbuds push a frame of their own whenever something is changed on the
# device itself -- a pinch, or the phone app. These arrive unprompted, carry
# sequence 0, and use control word 0x0100 rather than the 0x0160 we send,
# which means bit 0x20 is clear and they have no CRC trailer. Confirmed on
# Ear (a) firmware 1.0.1.51; see knowledge/.
DIR_EVENT = 0xE0
EVENT_ANC = 0x03
# Sent twice when the case is closed with the earbuds inside.
# Note 0x02 paired with DIR_SET is find-my instead, which is exactly why
# messages are keyed on (opcode, direction) and never opcode alone.
EVENT_CASE_CLOSED = 0x02
REPLY_DIRECTIONS = (DIR_RESPONSE, DIR_ACK)

# Opcode bytes are not globally unique -- 0x44 is both ring-legacy and
# custom-EQ-get, 0x41 is both latency-get and custom-EQ-set. Only the pair
# (opcode, direction) identifies a message, so never key on opcode alone.
CMD_DEVICE_INFO = 0x06
CMD_BATTERY = 0x07
CMD_IED_SET = 0x04
CMD_IED_GET = 0x0E
CMD_ANC_SET = 0x0F
CMD_EQ_SET = 0x10
CMD_ANC_GET = 0x1E
CMD_EQ_GET = 0x1F
CMD_LATENCY_SET = 0x40
CMD_LATENCY_GET = 0x41
CMD_FIRMWARE = 0x42
CMD_BASS_GET = 0x4E
CMD_BASS_SET = 0x51

# 6 is absent from the wire enum; the gap is real, not a transcription slip.
ANC_MODES = {"high": 1, "mid": 2, "low": 3, "adaptive": 4, "off": 5, "transparency": 7}
ANC_NAMES = {value: name for name, value in ANC_MODES.items()}

# Per-model capabilities.
#
# Battery and noise control are safe to assume: the component ids and the
# noise-control enum are the same on every model checked, CMF included.
# Equaliser ids and the bass encoding are *not* safe -- CMF uses a different
# preset set entirely, and the bass doubling applies to only some model bases.
# So a device we have not verified gets battery, noise control, latency and
# wear detection, and its equaliser and bass are left alone rather than
# guessed at.
#
# `pattern` is matched against the Bluetooth name, lowercased. Serial-prefix
# tables are unreliable here: they misread Ear (a) as Ear (1).
MODELS = [
  {
    "base": "B162",
    "name": "Nothing Ear (a)",
    "pattern": r"nothing ear \(a\)",
    "channel": 15,
    "support": "verified",
    # Verified id by id against the Nothing X app, 2026-09-20. Id 4 is Dirac
    # Opteo, which the app can display but not select.
    "eq": {
      "balanced": 0,
      "voice": 1,
      "more_treble": 2,
      "more_bass": 3,
      "dirac": 4,
      "custom": 5,
    },
    "bass_max": 5,
  },
]


def valid_pattern(pattern):
  if not isinstance(pattern, str):
    return False
  try:
    re.compile(pattern)
  except re.error:
    return False
  return True


def load_local_models(models):
  """Overlay confirmed models from models.local.json.

  Hand-editable, so a bad entry is skipped: every command resolves a model
  first, and raising here would take battery and noise control down with it.
  """
  path = os.path.join(os.path.dirname(__file__), "models.local.json")
  try:
    with open(path, encoding="utf-8") as stream:
      overrides = json.load(stream)
  except (FileNotFoundError, json.JSONDecodeError, OSError):
    return models
  if not isinstance(overrides, list):
    return models

  merged = list(models)
  for override in overrides:
    if not isinstance(override, dict):
      continue
    pattern = override.get("pattern")
    if pattern is not None and not valid_pattern(pattern):
      continue
    entry = dict(override)
    if "name" in entry and not isinstance(entry["name"], str):
      entry["name"] = ""
    if "channel" in entry and not isinstance(entry["channel"], int):
      entry["channel"] = RFCOMM_CHANNEL

    base = entry.get("base")
    index = next((i for i, model in enumerate(merged)
                  if (base and model.get("base") == base)
                  or (pattern and model.get("pattern") == pattern)), None)
    if index is None:
      # Matched and dialled on its own, so it has to carry every indexed field.
      if not valid_pattern(pattern) or not isinstance(base, str) or not base:
        continue
      merged.append({"name": "", "channel": RFCOMM_CHANNEL, **entry})
    else:
      merged[index] = {**merged[index], **entry}
  return merged


MODELS = load_local_models(MODELS)

UNKNOWN_MODEL = {
  "base": "unknown",
  "name": "",
  "pattern": None,
  "channel": RFCOMM_CHANNEL,
  "eq": None,
  "bass_max": None,
}


def resolve_model(device_name):
  lowered = str(device_name or "").lower()
  for model in MODELS:
    if re.search(model["pattern"], lowered):
      return model
  return UNKNOWN_MODEL


def support_state(model):
  if model.get("base") == "unknown":
    return "unknown"
  return model.get("support", "identified")


def eq_names_for(model):
  table = model.get("eq") or {}
  return {value: name for name, value in table.items()}

BATTERY_COMPONENTS = {1: "both", 2: "left", 3: "right", 4: "case"}

MAX_FRAME_BUFFER = 8192
# BlueZ reports the link up slightly before the control channel is ready, and
# keeps it marked busy for a moment after a write. These are the delays that
# make rapid clicks and fresh connections behave.
SETTLE_AFTER_SET = 0.35
RETRY_AFTER_WRITE = 0.3
RETRY_FOR_CASE = 0.7
BUSY_ERRNOS = (errno.EBUSY, errno.EAGAIN, errno.EINPROGRESS, errno.ETIMEDOUT)

CASE_CACHE_MAX_AGE = 6 * 3600
HELPER_VERSION = "0.2.0"
RESYNC_MIN_INTERVAL = 2.0


def crc16(data):
  """CRC-16 with polynomial 0xA001 and init 0xFFFF, over the whole frame.

  Both reference implementations call this "ARC", but ARC inits to 0x0000 and
  this inits to 0xFFFF, which are MODBUS parameters. The bytes are what the
  device validates, so the name is left alone and the behaviour documented.
  """
  crc = 0xFFFF
  for byte in data:
    crc ^= byte
    for _ in range(8):
      crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
  return crc & 0xFFFF


def build_frame(opcode, direction, payload=b"", seq=1):
  wire = (opcode & 0xFF) | ((direction & 0xFF) << 8)
  body = struct.pack("<BHHH", SOF, CTRL_WITH_CRC, wire, len(payload))
  body += bytes([seq & 0xFF]) + payload
  return body + struct.pack("<H", crc16(body))


class Frame:
  __slots__ = ("opcode", "direction", "seq", "payload")

  def __init__(self, opcode, direction, seq, payload):
    self.opcode = opcode
    self.direction = direction
    self.seq = seq
    self.payload = payload


class FrameParser:
  """Resynchronising byte-stream parser.

  Garbage before a SOF is discarded rather than fatal, and the buffer is
  bounded so a corrupted stream cannot grow it without limit.
  """

  def __init__(self):
    self._buf = bytearray()

  def feed(self, data):
    self._buf.extend(data)
    if len(self._buf) > MAX_FRAME_BUFFER:
      del self._buf[:len(self._buf) - MAX_FRAME_BUFFER]

  def frames(self):
    while True:
      start = self._buf.find(SOF)
      if start < 0:
        self._buf.clear()
        return
      if start:
        del self._buf[:start]
      if len(self._buf) < HEADER_SIZE:
        return
      _sof, ctrl, command, length = struct.unpack_from("<BHHH", self._buf)
      crc_size = 2 if ctrl & CRC_PRESENT_BIT else 0
      total = HEADER_SIZE + length + crc_size
      if len(self._buf) < total:
        return
      raw = bytes(self._buf[:total])
      del self._buf[:total]
      if crc_size and crc16(raw[:-2]) != struct.unpack_from("<H", raw, total - 2)[0]:
        continue
      yield Frame(
        opcode=command & 0xFF,
        direction=(command >> 8) & 0xFF,
        seq=raw[7],
        payload=raw[HEADER_SIZE:HEADER_SIZE + length],
      )


class ControlBusy(Exception):
  """The one RFCOMM control slot is held by something else."""


class Session:
  def __init__(self, address, channel=RFCOMM_CHANNEL, timeout=2.0):
    self.address = address
    self.channel = channel
    self.timeout = timeout
    self.sock = None
    self.parser = FrameParser()
    self.events = []
    self._seq = 0

  def __enter__(self):
    self.open()
    return self

  def __exit__(self, *_exc):
    self.close()
    return False

  def open(self):
    last = None
    for attempt in range(6):
      sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
      sock.settimeout(self.timeout)
      try:
        sock.connect((self.address, self.channel))
      except OSError as exc:
        sock.close()
        last = exc
        if exc.errno in BUSY_ERRNOS:
          time.sleep(0.7 + attempt * 0.35)
          continue
        raise
      else:
        self.sock = sock
        # The device ignores queries on a fresh session until it has answered
        # something harmless first. Nothing X opens the same way.
        self.request(CMD_DEVICE_INFO, DIR_GET, timeout=0.8)
        return
    raise ControlBusy(str(last) if last else "control channel unavailable")

  def close(self):
    if self.sock is not None:
      try:
        self.sock.close()
      finally:
        self.sock = None

  def _next_seq(self):
    self._seq = (self._seq % 250) + 1
    return self._seq

  def send(self, opcode, direction, payload=b""):
    seq = self._next_seq()
    self.sock.sendall(build_frame(opcode, direction, payload, seq))
    return seq

  def request(self, opcode, direction=DIR_GET, payload=b"", timeout=1.6):
    """Send one frame and wait for its reply.

    Replies are matched on opcode, direction and the echoed sequence byte.
    Matching on opcode alone lets a late reply to an earlier request satisfy
    the wrong caller. Frames that match nothing pending are kept as events.
    """
    seq = self.send(opcode, direction, payload)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
      for frame in self.read_frames(deadline):
        if (frame.opcode == opcode
            and frame.direction in REPLY_DIRECTIONS
            and frame.seq == seq):
          return frame.payload
        self.events.append(frame)
    return None

  def read_frames(self, deadline):
    remaining = max(0.05, min(0.25, deadline - time.monotonic()))
    self.sock.settimeout(remaining)
    try:
      chunk = self.sock.recv(1024)
    except socket.timeout:
      return []
    except OSError:
      return []
    if not chunk:
      return []
    self.parser.feed(chunk)
    return list(self.parser.frames())

  def drain(self, seconds):
    """Collect unsolicited frames for a while. Used by `listen`."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
      for frame in self.read_frames(deadline):
        self.events.append(frame)


def parse_battery(payload):
  if not payload:
    return {}
  out = {}
  count = payload[0]
  for index in range(count):
    base = 1 + index * 2
    if base + 1 >= len(payload):
      break
    name = BATTERY_COMPONENTS.get(payload[base])
    if name is None:
      continue
    raw = payload[base + 1]
    entry = {"level": raw & 0x7F, "charging": bool(raw & 0x80), "available": True, "stale": False}
    # Some firmware reports one shared value for both buds.
    for key in ("left", "right") if name == "both" else (name,):
      out[key] = dict(entry)
  return out


def parse_anc(payload):
  """Scan the TLV-ish payload in 3-byte steps.

  kind 1 carries the mode, kind 2 the strength. They are orthogonal: "off" is
  a mode, not a strength of zero, so the two are reported separately.
  """
  mode = None
  level = None
  for base in range(0, len(payload) - 2, 3):
    kind, value = payload[base], payload[base + 1]
    if kind == 1 and mode is None:
      mode = value
    elif kind == 2 and level is None:
      level = value
  return {
    "mode": ANC_NAMES.get(mode, "unknown" if mode is not None else ""),
    "raw": mode,
    "level": level,
    "available": mode is not None,
  }


def parse_eq(payload, model):
  # `presets` is what the panel may offer: an overlay can confirm only some.
  presets = sorted(model.get("eq") or {})
  if not payload:
    return {"preset": "", "raw": None, "presets": presets, "available": False}
  return {
    "preset": eq_names_for(model).get(payload[0], "unknown"),
    "raw": payload[0],
    "presets": presets,
    "available": True,
  }


# Bass enhance is a pair: an on/off flag and a level carried at twice its
# face value, so level 3 goes over the wire as 6. The usable range is 0-5.
BASS_MAX_LEVEL = 5


def parse_bass(payload):
  if len(payload) < 2:
    return {"enabled": False, "level": None, "available": False}
  return {
    "enabled": bool(payload[0]),
    "level": payload[1] / 2.0,
    "available": True,
  }


BOOL_VALUES = {"on": True, "off": False}


def eq_wire_id(value, model):
  """Accept a preset name, or a raw id for verifying the mapping itself.

  Testing a label by sending a label is circular: it can only confirm the map
  agrees with itself. A raw id lets an external oracle -- the phone app --
  say what the device really applied, which is how this model's ids were
  established and how another model's should be.
  """
  if value.isdigit():
    raw = int(value)
    if not 0 <= raw <= 255:
      raise ValueError("eq id must be between 0 and 255")
    return raw
  table = model.get("eq")
  if not table:
    raise ValueError(
      "preset names are not known for this device (%s); send a raw id instead, "
      "and see `probe` to help map it" % (model.get("name") or "unrecognised"))
  if value not in table:
    raise ValueError("unknown preset %r; expected one of: %s, or a raw id"
                     % (value, ", ".join(sorted(table))))
  return table[value]


def bool_value(value):
  if value not in BOOL_VALUES:
    raise ValueError("expected 'on' or 'off', got %r" % value)
  return BOOL_VALUES[value]


def bass_wire_level(value):
  """Validate `off` or a level from 0 to 5, returning the wire level or None."""
  if value == "off":
    return None
  level = float(value)
  if not 0 <= level <= BASS_MAX_LEVEL:
    raise ValueError("bass level must be between 0 and %d" % BASS_MAX_LEVEL)
  return int(level * 2)


def parse_latency(payload):
  """Low latency mode. Note the wire is 1 for on and 2 for off, not 0."""
  if not payload:
    return {"enabled": False, "available": False}
  return {"enabled": payload[0] == 1, "available": True}


# The wear-detection reply is a block of device toggles, not a single value:
# a count byte followed by that many (key, value) pairs. Wear detection is the
# entry under key 0x01. The other keys are unmapped and carried through as-is
# so they can be identified later without another capture.
IED_KEY_IN_EAR = 0x01


def parse_toggle_block(payload):
  out = {}
  if not payload:
    return out
  count = payload[0]
  for index in range(count):
    base = 1 + index * 2
    if base + 1 >= len(payload):
      break
    out[payload[base]] = payload[base + 1]
  return out


def parse_in_ear(payload):
  """Whether wear detection is switched on, not whether a bud is in an ear."""
  flags = parse_toggle_block(payload)
  if IED_KEY_IN_EAR not in flags:
    return {"enabled": False, "available": False, "flags": {}}
  return {
    "enabled": bool(flags[IED_KEY_IN_EAR]),
    "available": True,
    # Keyed by decimal string so the JSON survives a round trip unchanged.
    "flags": dict((str(k), v) for k, v in sorted(flags.items())),
  }


def parse_serial(payload):
  text = payload.decode("ascii", errors="ignore")
  for line in text.splitlines():
    parts = [part.strip() for part in line.strip().split(",")]
    if len(parts) == 3 and parts[1] == "4" and parts[2]:
      return parts[2]
  return ""


def parse_firmware(payload):
  return payload.decode("ascii", errors="ignore").strip("\x00 \t\r\n")


def state_dir():
  base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
  return os.path.join(base, "nothing-control")


def case_cache_path(address):
  safe = address.replace(":", "").lower()
  return os.path.join(state_dir(), "case-%s.json" % safe)


def load_case_cache(address):
  try:
    with open(case_cache_path(address), "r", encoding="utf-8") as handle:
      cached = json.load(handle)
  except (OSError, ValueError):
    return None
  if not isinstance(cached, dict):
    return None
  if time.time() - cached.get("at", 0) > CASE_CACHE_MAX_AGE:
    return None
  level = cached.get("level")
  if not isinstance(level, int):
    return None
  # A cached reading is never reported as charging: the lid is shut, so we
  # cannot know, and a frozen "charging" badge reads as a bug.
  return {"level": level, "charging": False, "available": True, "stale": True}


def save_case_cache(address, entry):
  try:
    os.makedirs(state_dir(), exist_ok=True)
    with open(case_cache_path(address), "w", encoding="utf-8") as handle:
      json.dump({"level": entry["level"], "at": time.time()}, handle)
  except OSError:
    pass


def bluez_info(address):
  try:
    result = subprocess.run(
      ["bluetoothctl", "info", address],
      capture_output=True, text=True, timeout=4, check=False,
    )
  except (OSError, subprocess.SubprocessError):
    return ""
  return result.stdout


def bluez_state(address):
  """Connection state and aggregate battery, for the degraded path."""
  text = bluez_info(address)
  battery = -1
  match = re.search(r"Battery Percentage:\s*0x[0-9a-f]+\s*\((\d+)\)", text, re.I)
  if match:
    battery = int(match.group(1))
  name = ""
  match = re.search(r"^\s*Name:\s*(.+)$", text, re.M)
  if match:
    name = match.group(1).strip()
  return {
    "connected": bool(re.search(r"^\s*Connected:\s*yes", text, re.M)),
    "paired": bool(re.search(r"^\s*Paired:\s*yes", text, re.M)),
    "aggregateBattery": battery,
    "name": name,
  }


def find_device():
  """First paired device that looks like a Nothing/CMF product."""
  try:
    result = subprocess.run(
      ["bluetoothctl", "devices"],
      capture_output=True, text=True, timeout=4, check=False,
    )
  except (OSError, subprocess.SubprocessError):
    return ""
  for line in result.stdout.splitlines():
    parts = line.split(None, 2)
    if len(parts) < 3 or parts[0] != "Device":
      continue
    name = parts[2].lower()
    if "nothing" in name or "cmf" in name or "ear" in name:
      return parts[1]
  return ""


def read_status(session, address, model):
  status = {}
  status["serial"] = parse_serial(session.request(CMD_DEVICE_INFO, DIR_GET) or b"")
  status["firmware"] = parse_firmware(session.request(CMD_FIRMWARE, DIR_GET) or b"")

  battery = parse_battery(session.request(CMD_BATTERY, DIR_GET) or b"")
  # The case only reports while its lid is open. A single miss is ambiguous --
  # a closed lid and a dropped frame look identical -- so retry once before
  # falling back to the cache.
  if "case" not in battery:
    time.sleep(RETRY_FOR_CASE)
    retry = parse_battery(session.request(CMD_BATTERY, DIR_GET) or b"")
    if retry:
      battery.update(retry)
  if "case" in battery:
    save_case_cache(address, battery["case"])
  else:
    cached = load_case_cache(address)
    battery["case"] = cached or {"level": None, "charging": False, "available": False, "stale": False}
  status["battery"] = battery

  # Optional reads are attempted and allowed to fail: the UI gates each row on
  # whether the read succeeded, rather than on a hardcoded model table.
  status["anc"] = parse_anc(session.request(CMD_ANC_GET, DIR_GET) or b"")

  # Gated on the model having a mapping, not on the device answering: an
  # unmapped device answers and accepts writes, the ids just mean something else.
  if model.get("eq"):
    status["eq"] = parse_eq(session.request(CMD_EQ_GET, DIR_GET) or b"", model)
  if model.get("bass_max"):
    status["bass"] = parse_bass(session.request(CMD_BASS_GET, DIR_GET) or b"")
  status["latency"] = parse_latency(session.request(CMD_LATENCY_GET, DIR_GET) or b"")
  status["inEar"] = parse_in_ear(session.request(CMD_IED_GET, DIR_GET) or b"")
  return status


def blank_status(address, bluez):
  return {
    "ok": True,
    "address": address,
    "name": bluez.get("name", ""),
    "connected": bluez.get("connected", False),
    "paired": bluez.get("paired", False),
    "protocol": False,
    "aggregateBattery": bluez.get("aggregateBattery", -1),
    "serial": "",
    "firmware": "",
    "battery": {},
    "anc": {"mode": "", "raw": None, "level": None, "available": False},
    "eq": {"preset": "", "raw": None, "presets": [], "available": False},
    "bass": {"enabled": False, "level": None, "available": False},
    "model": {"base": "unknown", "name": "", "known": False},
    "latency": {"enabled": False, "available": False},
    "inEar": {"enabled": False, "available": False, "flags": {}},
    "events": [],
    "error": "",
    "errorCode": "",
  }


# Opcodes that do something rather than report something. A sweep must not
# touch these: ringing earbuds that are in someone's ears is loud, and the
# fit test hijacks the device for half a minute.
PROBE_SKIP = {0x02, 0x14, 0x44}


def redact(opcode, payload):
  """Hex for the report, minus anything personally identifying.

  The device-info block is ASCII and carries the serial number and the
  Bluetooth address. Its *shape* is what helps map a model, so the field
  structure is kept and the values are dropped. A report nobody can safely
  paste in public is a report nobody will send.
  """
  if opcode != CMD_DEVICE_INFO:
    return payload.hex(":") or "(empty)"
  rows = []
  for line in payload[1:].decode("ascii", errors="replace").splitlines():
    parts = line.split(",")
    if len(parts) == 3:
      rows.append("%s,%s,<%d chars>" % (parts[0], parts[1], len(parts[2])))
  return "redacted; fields: " + "; ".join(rows) if rows else "redacted"


def probe(session, address, bluez, model):
  """Collect everything a new device will answer, as a pasteable report.

  Only GET is sent. The point is that someone with hardware we cannot buy can
  run one command and hand back enough to map their model, without having to
  understand the protocol.
  """
  answers = []
  for opcode in range(0x00, 0x100):
    if opcode in PROBE_SKIP:
      continue
    try:
      payload = session.request(opcode, DIR_GET, timeout=0.22)
    except OSError:
      continue
    if payload is not None:
      answers.append((opcode, payload))

  info = {}
  for opcode, payload in answers:
    if opcode == CMD_DEVICE_INFO:
      info["device_info"] = payload.decode("ascii", errors="replace")

  lines = []
  lines.append("### Device")
  lines.append("")
  lines.append("| field | value |")
  lines.append("| --- | --- |")
  lines.append("| Bluetooth name | `%s` |" % bluez.get("name", ""))
  lines.append("| Detected as | `%s` |" % (model["base"] if model["base"] != "unknown"
                                           else "unrecognised"))
  lines.append("| RFCOMM channel | `%d` |" % session.channel)
  lines.append("| Firmware | `%s` |" % parse_firmware(
    dict(answers).get(CMD_FIRMWARE, b"")))
  lines.append("| Helper version | `%s` |" % HELPER_VERSION)
  lines.append("")
  lines.append("### Opcodes answered (%d)" % len(answers))
  lines.append("")
  lines.append("| opcode | response |")
  lines.append("| --- | --- |")
  for opcode, payload in answers:
    lines.append("| `0x%02x` | `%s` |" % (opcode, redact(opcode, payload)))
  lines.append("")
  lines.append("### Decoded")
  lines.append("")
  lines.append("```")
  battery = parse_battery(dict(answers).get(CMD_BATTERY, b""))
  lines.append("battery       %s" % json.dumps(battery, sort_keys=True))
  lines.append("noise control %s" % json.dumps(
    parse_anc(dict(answers).get(CMD_ANC_GET, b"")), sort_keys=True))
  lines.append("eq raw byte   %s" % (dict(answers).get(CMD_EQ_GET, b"").hex() or "no reply"))
  lines.append("bass raw      %s" % (dict(answers).get(CMD_BASS_GET, b"").hex() or "no reply"))
  lines.append("latency raw   %s" % (dict(answers).get(CMD_LATENCY_GET, b"").hex() or "no reply"))
  lines.append("wear block    %s" % json.dumps(
    parse_toggle_block(dict(answers).get(CMD_IED_GET, b"")), sort_keys=True))
  lines.append("```")
  lines.append("")
  lines.append("### Privacy")
  lines.append("")
  lines.append("The device-info block (`0x06`) is redacted above: it carries the serial")
  lines.append("number and the Bluetooth address in plain ASCII, and neither is needed")
  lines.append("to map a model. Its field structure is kept because that part is useful.")
  lines.append("Everything else is raw device state. Check it before posting if in doubt.")
  return "\n".join(lines)


def emit(payload):
  json.dump(payload, sys.stdout, separators=(",", ":"))
  sys.stdout.write("\n")
  sys.stdout.flush()


def watch(session, address, result, seconds, battery_interval):
  """Hold the session open and print a line whenever something changes.

  Only used while the panel is open. The control channel is single-occupancy,
  so holding it is a deliberate, bounded trade: instant updates for exactly as
  long as someone is looking at them, and the channel released the moment they
  are not.
  """
  # Emit only on a real change. The buds push several events for one physical
  # pinch, and handling them emits more still, so writing every time would
  # have the panel redraw repeatedly with identical content.
  last = None

  def publish():
    nonlocal last
    line = json.dumps(result, sort_keys=True, separators=(",", ":"))
    if line == last:
      return
    last = line
    emit(result)

  publish()
  deadline = time.monotonic() + seconds
  next_battery = time.monotonic() + battery_interval
  next_resync = 0.0

  while time.monotonic() < deadline:
    for frame in session.read_frames(min(deadline, next_battery)):
      if frame.direction != DIR_EVENT:
        continue
      if frame.opcode == EVENT_ANC:
        anc = parse_anc(frame.payload)
        if anc["available"]:
          result["anc"] = anc
          publish()
      elif time.monotonic() >= next_resync:
        # An unmapped event still means something changed, so re-read rather
        # than guess at its payload -- but rate limited, because a burst of
        # them would otherwise be a burst of full reads over RFCOMM.
        next_resync = time.monotonic() + RESYNC_MIN_INTERVAL
        result.update(read_status(session, address, model))
        publish()

    if time.monotonic() >= next_battery:
      next_battery = time.monotonic() + battery_interval
      result.update(read_status(session, address, model))
      publish()


def run(args):
  address = args.device or find_device()
  if not address:
    result = blank_status("", {})
    result["ok"] = False
    result["error"] = "No paired Nothing device found"
    result["errorCode"] = "no_device"
    return result

  bluez = bluez_state(address)
  model = resolve_model(bluez.get("name"))
  result = blank_status(address, bluez)
  result["model"] = {
    "base": model["base"],
    "name": model["name"],
    "known": model["base"] != "unknown",
    "support": support_state(model),
  }

  # Validate before looking at the link, so a typo is reported as a typo
  # rather than hidden behind whatever the connection happens to be doing.
  if args.command == "set-anc" and args.value not in ANC_MODES:
    result["ok"] = False
    result["error"] = "Unknown value %r; expected one of: %s" % (
      args.value, ", ".join(sorted(ANC_MODES)))
    result["errorCode"] = "bad_value"
    return result
  if args.command == "set-eq":
    try:
      eq_wire_id(args.value, model)
    except ValueError as exc:
      result["ok"] = False
      result["error"] = str(exc)
      result["errorCode"] = "bad_value"
      return result
  if args.command in ("set-latency", "set-in-ear"):
    try:
      bool_value(args.value)
    except ValueError as exc:
      result["ok"] = False
      result["error"] = str(exc)
      result["errorCode"] = "bad_value"
      return result
  if args.command == "set-bass":
    try:
      bass_wire_level(args.value)
    except ValueError as exc:
      result["ok"] = False
      result["error"] = str(exc)
      result["errorCode"] = "bad_value"
      return result

  if not bluez["connected"]:
    result["error"] = "Not connected"
    result["errorCode"] = "disconnected"
    return result

  try:
    channel = args.channel if args.channel else model["channel"]
    with Session(address, channel=channel) as session:
      result.update(read_status(session, address, model))
      result["protocol"] = True

      if args.command == "set-anc":
        session.request(CMD_ANC_SET, DIR_SET, bytes([1, ANC_MODES[args.value], 0]))
        time.sleep(RETRY_AFTER_WRITE)
        result["anc"] = parse_anc(session.request(CMD_ANC_GET, DIR_GET) or b"")
      elif args.command == "set-eq":
        session.request(CMD_EQ_SET, DIR_SET, bytes([eq_wire_id(args.value, model), 0]))
        time.sleep(RETRY_AFTER_WRITE)
        result["eq"] = parse_eq(session.request(CMD_EQ_GET, DIR_GET) or b"", model)
      elif args.command == "read-eq":
        result["eq"] = parse_eq(
          session.request(CMD_EQ_GET, DIR_GET) or b"", {"eq": {}})
      elif args.command == "set-bass" and not model.get("bass_max"):
        result["ok"] = False
        result["error"] = ("bass enhance is not mapped for this device (%s)"
                           % (model["name"] or "unrecognised"))
        result["errorCode"] = "unsupported"
      elif args.command == "set-bass":
        wire = bass_wire_level(args.value)
        if wire is None:
          # Turning the effect off must not discard the level the user chose,
          # so the stored one is read back and written alongside the flag.
          current = parse_bass(session.request(CMD_BASS_GET, DIR_GET) or b"")
          stored = current["level"] if current["available"] else 0
          session.request(CMD_BASS_SET, DIR_SET, bytes([0, int(stored * 2)]))
        else:
          session.request(CMD_BASS_SET, DIR_SET, bytes([1, wire]))
        time.sleep(RETRY_AFTER_WRITE)
        result["bass"] = parse_bass(session.request(CMD_BASS_GET, DIR_GET) or b"")
      elif args.command == "set-latency":
        # 1 enables, 2 disables. Zero is not the off value here.
        enabled = bool_value(args.value)
        session.request(CMD_LATENCY_SET, DIR_SET, bytes([1 if enabled else 2, 0]))
        time.sleep(RETRY_AFTER_WRITE)
        result["latency"] = parse_latency(session.request(CMD_LATENCY_GET, DIR_GET) or b"")
      elif args.command == "set-in-ear":
        enabled = bool_value(args.value)
        session.request(CMD_IED_SET, DIR_SET, bytes([1, 1, 1 if enabled else 0]))
        time.sleep(RETRY_AFTER_WRITE)
        result["inEar"] = parse_in_ear(session.request(CMD_IED_GET, DIR_GET) or b"")
      elif args.command == "probe":
        sys.stdout.write(probe(session, address, bluez, model) + "\n")
        return None
      elif args.command == "listen":
        session.drain(args.seconds)
      elif args.command == "watch":
        watch(session, address, result, args.seconds, args.battery_interval)
        return None

      if args.command != "status":
        # BlueZ keeps the channel busy briefly after the final ACK. Letting it
        # settle before close is what makes rapid bar clicks reliable.
        time.sleep(SETTLE_AFTER_SET)

      result["events"] = [
        {
          "opcode": "0x%02x" % frame.opcode,
          "direction": "0x%02x" % frame.direction,
          "seq": frame.seq,
          "payload": frame.payload.hex(),
        }
        for frame in session.events
      ]
  except ControlBusy as exc:
    result["error"] = "Control channel busy - another app is holding it"
    result["errorCode"] = "busy"
    result["detail"] = str(exc)
  except KeyError:
    result["ok"] = False
    result["error"] = "Unknown value: %s" % args.value
    result["errorCode"] = "bad_value"
  except OSError as exc:
    result["error"] = exc.strerror or str(exc)
    result["errorCode"] = "io"
  return result


def main(argv=None):
  parser = argparse.ArgumentParser(description="Nothing Ear (a) control helper")
  parser.add_argument("command", nargs="?", default="status",
                      choices=["status", "set-anc", "set-eq", "read-eq", "set-bass",
                               "set-latency", "set-in-ear", "listen", "watch", "probe"])
  parser.add_argument("value", nargs="?", default="")
  parser.add_argument("--device", default="", help="Bluetooth address; auto-detected when omitted")
  parser.add_argument("--channel", type=int, default=0,
                      help="override the channel the detected model implies")
  parser.add_argument("--seconds", type=float, default=20.0, help="listen/watch duration")
  parser.add_argument("--battery-interval", type=float, default=60.0,
                      help="seconds between battery re-reads while watching")
  args = parser.parse_args(argv)

  result = run(args)
  if result is None:
    return 0
  emit(result)
  return 0 if result.get("ok") else 1


if __name__ == "__main__":
  sys.exit(main())
