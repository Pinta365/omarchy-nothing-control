"""Protocol tests for the Nothing Ear helper.

Standard library only, matching the helper itself:
    /usr/bin/python3 -m unittest discover -s tests -v
"""

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "helper"))

import nothing_ear as ne

EAR_A = ne.MODELS[0]


class Crc(unittest.TestCase):
  def test_check_vector(self):
    # 0x4B37 is the published check value for CRC-16/MODBUS. The reference
    # implementations name this "ARC", which inits to 0x0000 and would give a
    # different answer; this pins the parameters that actually work.
    self.assertEqual(ne.crc16(b"123456789"), 0x4B37)


class Frames(unittest.TestCase):
  # Captured from real hardware: what is sent when ANC goes to transparency.
  CAPTURED = bytes.fromhex("556001 0ff0 0300 cb 010700 c5af".replace(" ", ""))

  def test_encoder_reproduces_a_real_packet(self):
    built = ne.build_frame(
      ne.CMD_ANC_SET, ne.DIR_SET,
      bytes([1, ne.ANC_MODES["transparency"], 0]), seq=0xCB)
    self.assertEqual(built, self.CAPTURED)

  def test_decoder_reads_a_real_packet(self):
    parser = ne.FrameParser()
    parser.feed(self.CAPTURED)
    frame = next(iter(parser.frames()))
    self.assertEqual(frame.opcode, ne.CMD_ANC_SET)
    self.assertEqual(frame.direction, ne.DIR_SET)
    self.assertEqual(frame.seq, 0xCB)
    self.assertEqual(frame.payload, bytes([1, 7, 0]))

  def test_resyncs_past_leading_garbage(self):
    parser = ne.FrameParser()
    parser.feed(b"\x00\xff junk " + self.CAPTURED)
    self.assertEqual(len(list(parser.frames())), 1)

  def test_waits_for_a_split_frame(self):
    parser = ne.FrameParser()
    parser.feed(self.CAPTURED[:5])
    self.assertEqual(list(parser.frames()), [])
    parser.feed(self.CAPTURED[5:])
    self.assertEqual(len(list(parser.frames())), 1)

  def test_drops_a_corrupted_frame(self):
    bad = bytearray(self.CAPTURED)
    bad[-1] ^= 0xFF
    parser = ne.FrameParser()
    parser.feed(bytes(bad))
    self.assertEqual(list(parser.frames()), [])

  def test_event_frame_has_no_crc(self):
    # Pushed frames use control word 0x0100, so bit 0x20 is clear and there is
    # no CRC trailer. Assuming one would mis-frame these and desync the stream.
    import struct
    payload = bytes([1, 7, 0])
    raw = struct.pack("<BHHH", ne.SOF, 0x0100,
                      ne.EVENT_ANC | (ne.DIR_EVENT << 8), len(payload))
    raw += bytes([0]) + payload
    parser = ne.FrameParser()
    parser.feed(raw)
    frames = list(parser.frames())
    self.assertEqual(len(frames), 1)
    self.assertEqual(frames[0].direction, ne.DIR_EVENT)
    self.assertEqual(ne.parse_anc(frames[0].payload)["mode"], "transparency")

  def test_control_word_declares_a_tws_headset(self):
    # 0x0160 is not arbitrary: device type 1 in 0x0F00, sequenced, CRC present.
    self.assertEqual((ne.CTRL_WITH_CRC & ne.CTRL_DEVICE_TYPE_MASK) >> 8, 1)
    self.assertTrue(ne.CTRL_WITH_CRC & ne.CRC_PRESENT_BIT)

  def test_buffer_is_bounded(self):
    parser = ne.FrameParser()
    parser.feed(b"\x00" * (ne.MAX_FRAME_BUFFER * 3))
    self.assertLessEqual(len(parser._buf), ne.MAX_FRAME_BUFFER)


class Battery(unittest.TestCase):
  def test_components_and_charging_bit(self):
    got = ne.parse_battery(bytes([3, 2, 90, 3, 85 | 0x80, 4, 60]))
    self.assertEqual(got["left"]["level"], 90)
    self.assertFalse(got["left"]["charging"])
    self.assertEqual(got["right"]["level"], 85)
    self.assertTrue(got["right"]["charging"])
    self.assertEqual(got["case"]["level"], 60)

  def test_shared_component_fills_both_buds(self):
    got = ne.parse_battery(bytes([1, 1, 77]))
    self.assertEqual(got["left"]["level"], 77)
    self.assertEqual(got["right"]["level"], 77)

  def test_absent_case_is_simply_missing(self):
    self.assertNotIn("case", ne.parse_battery(bytes([2, 2, 90, 3, 90])))

  def test_empty(self):
    self.assertEqual(ne.parse_battery(b""), {})


class Anc(unittest.TestCase):
  def test_mode_and_level_are_separate_axes(self):
    got = ne.parse_anc(bytes([1, 7, 0, 2, 3, 0]))
    self.assertEqual(got["mode"], "transparency")
    self.assertEqual(got["level"], 3)

  def test_off_is_a_mode_not_a_zero_level(self):
    got = ne.parse_anc(bytes([1, 5, 0]))
    self.assertEqual(got["mode"], "off")
    self.assertIsNone(got["level"])

  def test_six_is_not_a_mode(self):
    # The wire enum skips 6; it must not resolve to a neighbour.
    self.assertEqual(ne.parse_anc(bytes([1, 6, 0]))["mode"], "unknown")

  def test_empty_is_unavailable(self):
    self.assertFalse(ne.parse_anc(b"")["available"])


class Eq(unittest.TestCase):
  def test_presets(self):
    # Ids verified against the vendor app for B162. Getting these wrong is
    # invisible in a round trip: you read back the number you wrote.
    self.assertEqual(ne.parse_eq(bytes([0]), EAR_A)["preset"], "balanced")
    self.assertEqual(ne.parse_eq(bytes([1]), EAR_A)["preset"], "voice")
    self.assertEqual(ne.parse_eq(bytes([2]), EAR_A)["preset"], "more_treble")
    self.assertEqual(ne.parse_eq(bytes([3]), EAR_A)["preset"], "more_bass")
    self.assertEqual(ne.parse_eq(bytes([5]), EAR_A)["preset"], "custom")

  def test_id_four_is_dirac_not_custom(self):
    # Confirmed in the vendor app. Mapping 4 to "custom" would apply Dirac
    # Opteo instead of the user's custom curve.
    self.assertEqual(ne.parse_eq(bytes([4]), EAR_A)["preset"], "dirac")
    self.assertEqual(ne.parse_eq(bytes([5]), EAR_A)["preset"], "custom")

  def test_empty_is_unavailable(self):
    self.assertFalse(ne.parse_eq(b"", EAR_A)["available"])


class EqWireId(unittest.TestCase):
  def test_names_resolve_through_the_map(self):
    self.assertEqual(ne.eq_wire_id("more_bass", EAR_A), 3)
    self.assertEqual(ne.eq_wire_id("voice", EAR_A), 1)

  def test_raw_ids_bypass_the_map(self):
    # The point of raw ids: verify the map without using the map.
    self.assertEqual(ne.eq_wire_id("3", EAR_A), 3)
    self.assertEqual(ne.eq_wire_id("0", EAR_A), 0)

  def test_rejects_nonsense(self):
    self.assertRaises(ValueError, ne.eq_wire_id, "bassy", EAR_A)
    self.assertRaises(ValueError, ne.eq_wire_id, "999", EAR_A)


class ModelDetection(unittest.TestCase):
  def test_ear_a_is_recognised_by_bluetooth_name(self):
    self.assertEqual(ne.resolve_model("Nothing Ear (a)")["base"], "B162")
    self.assertEqual(ne.resolve_model("anders nothing ear (a)")["base"], "B162")

  def test_other_devices_fall_back_to_unknown(self):
    # CMF uses a different preset set entirely, so guessing would mislabel it.
    for name in ("CMF Buds 2", "Nothing Ear (3)", "", None):
      self.assertEqual(ne.resolve_model(name)["base"], "unknown")

  def test_support_states_distinguish_unknown_and_incomplete_models(self):
    self.assertEqual(ne.support_state(ne.UNKNOWN_MODEL), "unknown")
    self.assertEqual(ne.support_state({"base": "B999"}), "identified")
    self.assertEqual(ne.support_state({"base": "B999", "support": "verified"}),
                     "verified")

  def test_unknown_model_refuses_preset_names(self):
    self.assertRaises(ValueError, ne.eq_wire_id, "more_bass", ne.UNKNOWN_MODEL)

  def test_unknown_model_still_allows_raw_ids(self):
    # Raw ids are how a new model gets mapped in the first place.
    self.assertEqual(ne.eq_wire_id("3", ne.UNKNOWN_MODEL), 3)

  def test_unknown_model_reports_no_preset_names(self):
    self.assertEqual(ne.parse_eq(bytes([3]), ne.UNKNOWN_MODEL)["preset"], "unknown")
    self.assertEqual(ne.parse_eq(bytes([3]), ne.UNKNOWN_MODEL)["raw"], 3)

  def test_a_reading_carries_the_presets_the_model_maps(self):
    self.assertEqual(ne.parse_eq(bytes([3]), EAR_A)["presets"],
                     ["balanced", "custom", "dirac", "more_bass",
                      "more_treble", "voice"])
    self.assertEqual(ne.parse_eq(bytes([3]), {"eq": {"balanced": 0, "more_bass": 3}})["presets"],
                     ["balanced", "more_bass"])
    self.assertEqual(ne.parse_eq(bytes([3]), ne.UNKNOWN_MODEL)["presets"], [])


class LocalModelOverlay(unittest.TestCase):
  """A bad entry must be skipped, not raised: resolve_model runs on every
  command, so a traceback takes the whole panel dark."""

  def overlay(self, contents):
    directory = tempfile.mkdtemp()
    self.addCleanup(shutil.rmtree, directory, True)
    with open(os.path.join(directory, "models.local.json"), "w",
              encoding="utf-8") as stream:
      stream.write(contents)
    original_file, original_models = ne.__file__, ne.MODELS
    self.addCleanup(setattr, ne, "MODELS", original_models)
    self.addCleanup(setattr, ne, "__file__", original_file)
    ne.__file__ = os.path.join(directory, "nothing_ear.py")
    ne.MODELS = ne.load_local_models(original_models)

  def test_a_confirmed_mapping_is_overlaid(self):
    self.overlay('[{"base": "local:cmf buds 2", "name": "CMF Buds 2",'
                 ' "pattern": "^cmf buds 2$", "channel": 15,'
                 ' "support": "identified", "eq": {"balanced": 0}}]')
    found = ne.resolve_model("CMF Buds 2")
    self.assertEqual(found["eq"], {"balanced": 0})
    self.assertEqual(ne.support_state(found), "identified")

  def test_malformed_entries_are_skipped_rather_than_raised(self):
    for contents in ('[{"base": "B999", "eq": {}}]',
                     '[{"base": "B998", "pattern": "cmf buds ((2"}]',
                     '[{"base": "B997", "pattern": null}]',
                     '[{"pattern": "^cmf buds 2$"}]',
                     '[["not", "a", "dict"]]',
                     '{"base": "B995"}',
                     'not json at all'):
      self.overlay(contents)
      self.assertEqual(ne.resolve_model("CMF Buds 2")["base"], "unknown",
                       msg=contents)
      self.assertEqual(ne.resolve_model("Nothing Ear (a)")["base"], "B162",
                       msg=contents)

  def test_an_overlay_merges_into_a_shipped_model(self):
    self.overlay('[{"base": "B162", "eq": {"balanced": 0}}]')
    found = ne.resolve_model("Nothing Ear (a)")
    self.assertEqual(found["eq"], {"balanced": 0})
    self.assertEqual(found["bass_max"], 5)


class Bass(unittest.TestCase):
  def test_level_is_carried_at_double(self):
    got = ne.parse_bass(bytes([1, 6]))
    self.assertTrue(got["enabled"])
    self.assertEqual(got["level"], 3.0)

  def test_disabled_keeps_its_level(self):
    got = ne.parse_bass(bytes([0, 6]))
    self.assertFalse(got["enabled"])
    self.assertEqual(got["level"], 3.0)

  def test_one_byte_payload_is_not_a_level(self):
    # Reading payload[-1] of a short reply as the level is the bug that wrote
    # a malformed frame to real hardware. Too short means unavailable.
    self.assertFalse(ne.parse_bass(bytes([6]))["available"])

  def test_wire_level_doubles_and_validates(self):
    self.assertEqual(ne.bass_wire_level("3"), 6)
    self.assertEqual(ne.bass_wire_level("5"), 10)
    self.assertIsNone(ne.bass_wire_level("off"))
    self.assertRaises(ValueError, ne.bass_wire_level, "6")
    self.assertRaises(ValueError, ne.bass_wire_level, "-1")


class Latency(unittest.TestCase):
  def test_off_is_two_not_zero(self):
    self.assertTrue(ne.parse_latency(bytes([1]))["enabled"])
    self.assertFalse(ne.parse_latency(bytes([2]))["enabled"])

  def test_empty_is_unavailable(self):
    self.assertFalse(ne.parse_latency(b"")["available"])


class ToggleBlock(unittest.TestCase):
  # Read from the device: a count byte then that many (key, value) pairs.
  REAL = bytes.fromhex("09" "0101" "0201" "0701" "0901" "0a01" "0b00" "0e01" "1201" "1501")

  def test_parses_every_pair(self):
    flags = ne.parse_toggle_block(self.REAL)
    self.assertEqual(len(flags), 9)
    self.assertEqual(flags[0x01], 1)
    self.assertEqual(flags[0x0B], 0)

  def test_in_ear_reads_its_key_not_an_offset(self):
    self.assertTrue(ne.parse_in_ear(self.REAL)["enabled"])

  def test_in_ear_is_unavailable_when_its_key_is_absent(self):
    self.assertFalse(ne.parse_in_ear(bytes([1, 0x02, 1]))["available"])

  def test_truncated_block_does_not_overrun(self):
    self.assertEqual(ne.parse_toggle_block(bytes([9, 1, 1])), {0x01: 1})


class Values(unittest.TestCase):
  def test_bool_value(self):
    self.assertTrue(ne.bool_value("on"))
    self.assertFalse(ne.bool_value("off"))
    self.assertRaises(ValueError, ne.bool_value, "yes")


if __name__ == "__main__":
  unittest.main()
