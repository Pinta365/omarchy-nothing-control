# Contributing

An Omarchy bar plugin for Nothing and CMF earbuds. A stdlib-only Python helper
talks to the earbuds over Bluetooth RFCOMM; the panel is QML.

To add support for a device, read [adding-a-device.md](adding-a-device.md)
first. If a coding agent is helping you, point it at that file and this one.

## Layout

| Path | What it is |
| --- | --- |
| `helper/nothing_ear.py` | RFCOMM client and protocol. `MODELS` is the device table. |
| `Model.js` | Parses helper output for the panel. No QML imports; unit tested. |
| `Service.qml` | Runs the helper, polls, holds state. |
| `Panel.qml` | The bar widget and its popup. |
| `tools/map-device.sh` | Guided probe, equaliser mapping, and local hotfix. |
| `tools/dev.sh` | Syncs the checkout into the live plugin folder. |
| `tests/` | `unittest` for the helper, `deno test` for `Model.js`. |

The wire format, its traps, and what is still unmapped are in the Protocol
section of `README.md`. Read it before changing anything on the wire.

## Rules

- **Nothing is guessed.** A value ships only once an external oracle has
  confirmed what it means: the Nothing X app, a packet capture, or an
  independent implementation. Writing a value and reading it back is not
  confirmation; it only shows the code agrees with itself.
- **The person with the earbuds is the oracle.** An agent cannot see the
  Nothing X app. It has to ask for a setting to be changed there and the app
  closed, then read the result, and never fill in what the app probably shows.
- **Only GET what is unexplored.** Never send a SET to an opcode whose meaning
  is not established. Never write the codec (`0x29`): the firmware acknowledges
  values it does not apply. Never send anything to the opcodes in
  `PROBE_SKIP`; they act rather than report, ringing the buds or starting a fit
  test.
- **One client at a time.** Only one program can hold the control channel.
  Close the Nothing X app and the panel before reading. The bar also polls every
  few minutes, so a read that fails as busy just needs a retry.
- **Run the helper as `/usr/bin/python3`.** Version-managed Pythons are usually
  built without Bluetooth socket support.
- **Nothing in the repo that acts on install.** `omarchy plugin add` clones the
  whole repository into the user's plugin folder, so every file ships. No
  symlinks: the validator rejects them, which would break installation for
  everyone. And no file that coding agents load on their own, such as
  `AGENTS.md` or `CLAUDE.md`: it would steer the agents of everyone who installs
  the plugin. CI fails on either.
- **Keep reports redacted.** The device-info block (`0x06`) carries the serial
  number and Bluetooth address, and `redact()` drops the values. Never paste a
  raw `0x06` payload into an issue or pull request.

## Checks

CI runs these. Run them before proposing a change:

```sh
/usr/bin/python3 -m unittest discover -s tests
deno test --allow-read tests/model_test.ts
shellcheck tools/*.sh
/usr/lib/qt6/bin/qmllint Panel.qml Service.qml NothingEarIcon.qml
omarchy plugin validate .
```

`tools/dev.sh` pushes the checkout into the live plugin. Add `--restart` when a
QML property, signal handler or IPC method changes; editing a file in place is
picked up without it.
