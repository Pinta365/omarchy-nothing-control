#!/usr/bin/env bash
# Collect a redacted device report, then map the EQ ids a user confirms in
# Nothing X. It never writes to the earbuds; the optional hotfix only writes
# a local model overlay for the installed plugin.
# No -e: a failed clipboard copy or an EOF at a prompt must not end the flow.
set -uo pipefail

REPO="Pinta365/omarchy-nothing-control"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$HERE/helper/nothing_ear.py"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/pinta365.nothing-control"
REPORT="$(mktemp -t nothing-control-mapping-XXXXXX.md)"
STATUS="$(mktemp -t nothing-control-status-XXXXXX.json)"
MAPPINGS="$(mktemp -t nothing-control-eq-XXXXXX.json)"

cleanup() {
  rm -f "$STATUS" "$MAPPINGS"
}
trap cleanup EXIT

printf '%s\n\n' "This checks a new device without changing its settings."
printf '%s\n\n' "Close the panel and Nothing X before each reading: only one app can use the control channel."
printf '%s\n\n' "Probing the earbuds. This sweeps every read-only opcode and takes about a minute."

if ! /usr/bin/python3 "$HELPER" probe > "$REPORT" 2>&1; then
  printf 'The probe failed. Are the earbuds connected, and is the panel closed?\n\n'
  cat "$REPORT"
  read -rp 'Press enter to close. '
  exit 1
fi

if ! /usr/bin/python3 "$HELPER" status > "$STATUS"; then
  printf 'Could not read the device status after probing.\n'
  read -rp 'Press enter to close. '
  exit 1
fi

printf '%s\n\n' "The probe is complete."
printf '%s\n' "Mapping the equaliser is optional, and it is the one thing the probe cannot"
printf '%s\n' "do on its own: each preset has to be chosen in Nothing X and read back here."
printf '%s\n\n' "Say no to go straight to the report."

printf '{}' > "$MAPPINGS"

# An empty list skips the loop, leaving a plain device report. Expressed this
# way because the heredocs inside the loop have to start at column 0.
PRESETS=()
read -rp "Map equaliser presets now? [y/N] " reply
if [[ ${reply,,} == "y" ]]; then
  PRESETS=("balanced:Balanced" "more_bass:More bass" "more_treble:More treble"
           "voice:Voice" "dirac:Dirac Opteo" "custom:Custom")
  printf '\n%s\n' "For each preset you use, choose it in Nothing X, close Nothing X, then return here."
  printf '%s\n\n' "Skip any preset your device does not offer."
fi

for entry in ${PRESETS[@]+"${PRESETS[@]}"}; do
  key="${entry%%:*}"
  label="${entry#*:}"
  read -rp "Map \"$label\"? [y/N] " reply
  if [[ ${reply,,} != "y" ]]; then
    continue
  fi

  read -rp "Select \"$label\" in Nothing X, close the app, then press enter here. "
  if ! raw="$(/usr/bin/python3 "$HELPER" read-eq)"; then
    printf 'Could not read the equaliser value; skipping "%s".\n' "$label"
    continue
  fi
  if ! /usr/bin/python3 - "$MAPPINGS" "$key" "$raw" <<'PY'
import json
import sys

path, key, payload = sys.argv[1:]
result = json.loads(payload)
raw = result.get("eq", {}).get("raw")
if not result.get("ok") or not isinstance(raw, int):
  raise SystemExit(1)
with open(path, "r+", encoding="utf-8") as stream:
  mappings = json.load(stream)
  if raw in mappings.values():
    raise SystemExit("that raw id is already mapped; check the selected preset")
  mappings[key] = raw
  stream.seek(0)
  json.dump(mappings, stream, sort_keys=True)
  stream.truncate()
PY
  then
    printf 'The helper did not return a usable, unique EQ id; skipping "%s".\n' "$label"
    continue
  fi
done

/usr/bin/python3 - "$STATUS" "$MAPPINGS" "$REPORT" <<'PY'
import json
import sys

status_path, mappings_path, report_path = sys.argv[1:]
with open(status_path, encoding="utf-8") as stream:
  status = json.load(stream)
with open(mappings_path, encoding="utf-8") as stream:
  mappings = json.load(stream)
with open(report_path, "a", encoding="utf-8") as stream:
  stream.write("\n\n### Equaliser verification\n\n")
  if mappings:
    stream.write("| Nothing X label | Raw EQ id |\n| --- | --- |\n")
    for label, raw in mappings.items():
      stream.write(f"| {label.replace('_', ' ')} | `{raw}` |\n")
    stream.write("\nThe values above were selected in Nothing X, then read after closing it.\n")
  else:
    stream.write("No equaliser presets were verified in this run.\n")
PY

printf '\n%s\n' "$(cat "$REPORT")"
printf '\n---\nSaved to: %s\n' "$REPORT"
if command -v wl-copy >/dev/null 2>&1; then
  wl-copy < "$REPORT" && printf 'Copied to the clipboard.\n'
fi

if [[ $(/usr/bin/python3 - "$MAPPINGS" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
  print("yes" if json.load(stream) else "no")
PY
) == "yes" ]]; then
  read -rp "Apply the confirmed EQ mapping as a local hotfix? [y/N] " reply
  if [[ ${reply,,} == "y" ]] && /usr/bin/python3 - "$STATUS" "$MAPPINGS" \
      "$PLUGIN_DIR/helper/models.local.json" <<'PY'
import json
import os
import re
import sys

status_path, mappings_path, output_path = sys.argv[1:]
with open(status_path, encoding="utf-8") as stream:
  status = json.load(stream)
with open(mappings_path, encoding="utf-8") as stream:
  mappings = json.load(stream)
name = str(status.get("name") or "").strip()
if not name or not mappings:
  raise SystemExit("a Bluetooth name and at least one confirmed EQ preset are required")
model = status.get("model") or {}
# A partial run over a verified model would narrow it, so refuse.
if model.get("support") == "verified":
  raise SystemExit("%s is already verified; a local hotfix would only narrow it"
                   % (model.get("name") or name))
base = str(model.get("base") or "unknown")
if base == "unknown":
  base = "local:" + name
# bass_max absent, not null: null would clear it on an existing entry.
override = {
  "base": base,
  "name": str(model.get("name") or name),
  "pattern": "^" + re.escape(name.lower()) + "$",
  "channel": 15,
  "support": "identified",
  "eq": mappings,
}
try:
  with open(output_path, encoding="utf-8") as stream:
    overrides = json.load(stream)
except FileNotFoundError:
  overrides = []
if not isinstance(overrides, list):
  raise SystemExit(f"{output_path} must contain a JSON list")
index = next((i for i, item in enumerate(overrides)
              if isinstance(item, dict) and item.get("pattern") == override["pattern"]), None)
if index is None:
  overrides.append(override)
else:
  overrides[index] = {**overrides[index], **override}
os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "w", encoding="utf-8") as stream:
  json.dump(overrides, stream, indent=2)
  stream.write("\n")
PY
  then
    printf 'Local hotfix saved. Reopen the panel to load the confirmed EQ controls.\n'
  else
    printf 'Could not save the local hotfix; the issue report is still available below.\n'
  fi
else
  printf 'No EQ mappings were confirmed, so no local hotfix is available.\n'
fi

TITLE="Device support: $(sed -n 's/^| Bluetooth name | `\(.*\)` |$/\1/p' "$REPORT" | head -1)"

printf '\nRead the report above before sending it. It contains your device state.\n\n'

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  read -rp "Open an issue on $REPO as $(gh api user --jq .login 2>/dev/null)? [y/N] " reply
  if [[ ${reply,,} == "y" ]]; then
    gh issue create --repo "$REPO" --title "$TITLE" --body-file "$REPORT" \
      && printf '\nThank you. That is enough to map the device.\n'
  else
    printf '\nNothing sent. The report is still at %s\n' "$REPORT"
  fi
else
  printf 'GitHub CLI is not set up, so nothing can be posted from here.\n'
  printf 'Open an issue and paste the report (it is on your clipboard):\n'
  printf '  https://github.com/%s/issues/new\n' "$REPO"
fi

printf '\n'
read -rp 'Press enter to close. '
