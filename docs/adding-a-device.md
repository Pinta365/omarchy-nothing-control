# Adding a device

For anyone with Nothing or CMF earbuds this plugin does not fully support yet.

You can follow this yourself, but it was written with coding agents in mind:
clone the repo, open it in Claude Code, Copilot, or a similar agent, and ask it
to help you add your earbuds. It will read `AGENTS.md` and this guide, and ask
you to confirm each value in the Nothing X app as it goes.

There are two ways to help, and most people only need the first.

- **Report it.** Run the mapper, which produces a redacted report and can fix
  your own install straight away. No code involved.
- **Ship it.** Turn that mapping into an entry in the plugin's device table and
  open a pull request, so everyone with the same earbuds gets it.

## What you need

- The earbuds, paired and connected to an Omarchy machine.
- A phone with the **Nothing X** app. It is the source of truth for what every
  value means, and nothing here replaces it.
- This repository cloned, and the plugin installed if you want the local fix.

## Report it

```sh
./tools/map-device.sh
```

The script sweeps every read-only opcode, then maps equaliser presets one at a
time: you pick a preset from the list (or type its name), select it in Nothing
X, close the app, and the script reads the id the earbuds report. At the end it
offers to apply what you confirmed as a local hotfix and to open an issue with
the report. It never writes anything to the earbuds.

That issue is enough for the maintainer to add the device. Stop here unless you
want to go further.

## Ship it

Everything below turns facts into a table entry. Establish each fact against
the app first; the entry is only a record of what was confirmed.

### 1. Confirm the facts

**Equaliser ids.** The mapper's report has them, one per preset, each read after
selecting that preset in the app. Map every preset the app offers. A preset the
app can show but not select, like Dirac Opteo on Ear (a), can still be confirmed:
write the id with `/usr/bin/python3 helper/nothing_ear.py set-eq <id>`, then open
the app and see which preset it shows.

**Bass enhance.** The encoding is not a table setting. The helper always sends
the level doubled (`[enabled, level * 2]`) and caps it at 5, and `bass_max` in
the table only switches the control on. So check before enabling it: set bass to
two different levels in the app, reading back after each, and confirm the second
byte is exactly twice the level every time. If it is not, the device needs a
code change, not a table entry. Say so in the issue and leave bass off.

**Channel.** 15 on every model seen so far. A wrong channel fails silently: the
connection opens and nothing answers. The test is a battery reading coming back,
not the connection succeeding.

**Name.** What the earbuds call themselves over Bluetooth, from the report's
`Bluetooth name` row.

To read one value after changing it in the app, close the app and run:

```sh
/usr/bin/python3 - <<'PY'
import sys
sys.path.insert(0, "helper")
import nothing_ear as ne

address = ne.find_device()
if not address or not ne.bluez_state(address)["connected"]:
  sys.exit("The earbuds are not connected.")
with ne.Session(address) as session:
  payload = session.request(ne.CMD_BASS_GET, ne.DIR_GET)
  print(payload.hex(":") if payload else "no reply")
PY
```

Swap `CMD_BASS_GET` for any other `CMD_*_GET` in the helper. Only ever send GETs
this way.

### 2. Add the entry

Add the device to `MODELS` in `helper/nothing_ear.py`, following the Ear (a)
entry:

```python
{
  "base": "B162",
  "name": "Nothing Ear (a)",
  "pattern": r"nothing ear \(a\)",
  "channel": 15,
  "support": "verified",
  "eq": {"balanced": 0, "voice": 1, "more_treble": 2, "more_bass": 3,
         "dirac": 4, "custom": 5},
  "bass_max": 5,
},
```

- **`base`** is a stable identifier. Ear (a) uses Nothing's model code. If you
  cannot establish the code from a source you can cite, keep the `local:<name>`
  form the mapper wrote and say so in the pull request.
- **`pattern`** is matched against the lowercased Bluetooth name with
  `re.search`. Leave it unanchored so renamed earbuds still match, but make it
  specific enough not to catch a sibling model.
- **`support`** is `"verified"` only when every equaliser id was confirmed
  against the app. Otherwise use `"identified"`, and the panel will say support
  is still being finished.
- **`eq`** holds the confirmed ids. Use the standard keys where the app's name
  matches one; the mapper already did this if you picked from its list.
- **`eq_labels`** is only needed for presets with no standard key, mapping each
  key to the exact name the app shows.
- **`bass_max`** is left out unless step 1 confirmed the encoding.

A new standard preset name, one likely to recur across models, goes into both
`STANDARD_PRESETS` in the helper and `EQ_PRESETS` in `Model.js`. A test fails if
the two lists differ.

### 3. Test it

In `tests/test_protocol.py`, add the new name to the detection tests:

```python
self.assertEqual(ne.resolve_model("Nothing Ear (a)")["base"], "B162")
```

`test_other_devices_fall_back_to_unknown` lists names that must stay
unrecognised, including `CMF Buds 2` and `Nothing Ear (3)`. If you just added
one of those, move it out of that list.

Then run the checks in `AGENTS.md`.

### 4. Document it

- Add the device to the **Verified** line in `README.md`, if it is verified.
- Anything that surprised you on the wire goes under the README's traps list.

### 5. Open the pull request

Include the evidence, not just the entry. The mapper's report shows the id read
for each preset. Also say which values were confirmed against the app and which
were not. A reviewer cannot re-check them without your earbuds.
