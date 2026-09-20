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
EQREAD="$(mktemp -t nothing-control-read-XXXXXX.json)"
PROGRESS="$(mktemp -t nothing-control-progress-XXXXXX.txt)"

# Colour only on a terminal that reports it, and never with NO_COLOR set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1 \
   && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"; C_RESET="$(tput sgr0)"
  C_HEAD="$(tput setaf 6)$(tput bold)"; C_OK="$(tput setaf 2)"
  C_WARN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_ASK="$(tput setaf 6)"
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_ASK=""
fi

STEP=0
heading() {
  STEP=$((STEP + 1))
  printf '\n%sStep %d of 3  %s%s\n' "$C_HEAD" "$STEP" "$1" "$C_RESET"
}
note() { printf '%s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
good() { printf '%s  OK  %s%s\n' "$C_OK" "$1" "$C_RESET"; }
warn() { printf '%s  !   %s%s\n' "$C_WARN" "$1" "$C_RESET"; }
oops() { printf '%s  x   %s%s\n' "$C_ERR" "$1" "$C_RESET"; }
ask() { local answer; read -rp "$(printf '%s%s%s ' "$C_ASK" "$1" "$C_RESET")" answer; REPLY_TEXT="$answer"; }

SPINNER_PID=""

# Only on a terminal: piped output would get a smear of carriage returns.
start_spinner() {
  if [[ ! -t 1 ]]; then
    printf '%s\n' "$1"
    return
  fi
  (
    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    i=0
    started=$SECONDS
    printf '\033[?25l'
    while :; do
      # Nothing until there is something true to show: the count exists only
      # once the sweep starts, and 0s while the channel opens is noise.
      detail=""
      if [[ -n "${2:-}" ]]; then
        [[ -s "$2" ]] && detail="  $(tail -n 1 "$2") opcodes"
      elif (( SECONDS - started >= 2 )); then
        detail="  $((SECONDS - started))s"
      fi
      printf '\r\033[K  %s %s%s ' "${frames[i % 10]}" "$1" "$detail"
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
}

stop_spinner() {
  [[ -n "$SPINNER_PID" ]] || return 0
  kill "$SPINNER_PID" 2>/dev/null
  wait "$SPINNER_PID" 2>/dev/null
  SPINNER_PID=""
  [[ -t 1 ]] && printf '\r\033[K\033[?25h'
  return 0
}

cleanup() {
  stop_spinner
  rm -f "$STATUS" "$MAPPINGS" "$EQREAD" "$PROGRESS"
}
trap cleanup EXIT

printf '\n%sNothing device mapping%s\n' "$C_BOLD" "$C_RESET"
note "Checks a new device and changes nothing on it."
note "Close the panel and Nothing X first: only one app can use the control channel."
note "The bar also checks the battery every few minutes; if a read fails as busy, try again."

heading "Probe"
note "Sweeps every read-only opcode. Takes about a minute."
ask "Press enter to start it."

/usr/bin/python3 "$HELPER" probe --progress > "$REPORT" 2> "$PROGRESS" &
probe_job=$!
start_spinner "Probing the earbuds" "$PROGRESS"
wait "$probe_job"
probe_rc=$?
stop_spinner

if [[ $probe_rc -ne 0 ]]; then
  oops "The probe failed. Are the earbuds connected, and is the panel closed?"
  printf '\n'
  cat "$REPORT"
  grep -v '^[0-9]\+/[0-9]\+$' "$PROGRESS"
  ask "Press enter to close."
  exit 1
fi
good "Probe complete"

/usr/bin/python3 "$HELPER" status > "$STATUS" &
status_job=$!
start_spinner "Reading device status"
wait "$status_job"
status_rc=$?
stop_spinner

if [[ $status_rc -ne 0 ]]; then
  oops "Could not read the device status after probing."
  ask "Press enter to close."
  exit 1
fi
good "Device identified"

heading "Equaliser (optional)"
note "The one thing the probe cannot do alone: each preset has to be chosen in"
note "Nothing X and read back here. Say no to go straight to the report."

printf '{}' > "$MAPPINGS"

ask "Map equaliser presets now? [y/N]"
reply="$REPLY_TEXT"
if [[ ${reply,,} == "y" ]]; then
  printf '\n'
  note "Say which preset it is, then select it in Nothing X and close the app."
  note "If yours is not in the list, type its name instead."
fi

# Named before it is read, so the prompt can say which preset to go and select.
while [[ ${reply,,} == "y" ]]; do
  printf '\n'
  /usr/bin/python3 - "$HERE/helper" <<'MENU'
import sys
sys.path.insert(0, sys.argv[1])
import nothing_ear as ne

print("Which preset are you mapping?")
for index, (_, text) in enumerate(ne.STANDARD_PRESETS, 1):
  print("  %d) %s" % (index, text))
MENU
  ask "Number, or the name your app uses:"
  choice="$REPLY_TEXT"
  if ! chosen="$(/usr/bin/python3 - "$HERE/helper" "$MAPPINGS" "$choice" <<'RESOLVE'
import json
import re
import sys

helper_dir, path, choice = sys.argv[1:]
sys.path.insert(0, helper_dir)
import nothing_ear as ne

choice = " ".join(choice.split())
# A number picks a standard preset; anything else is the name itself.
if choice.isdigit():
  index = int(choice)
  if not 1 <= index <= len(ne.STANDARD_PRESETS):
    sys.exit("there is no preset numbered %d" % index)
  name, label = ne.STANDARD_PRESETS[index - 1]
else:
  # The key is reduced to the shape the shipped names use.
  label = choice
  name = re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_")[:32]
if not name or name == "unknown":
  sys.exit('"%s" cannot be used as a preset name' % choice)
with open(path, encoding="utf-8") as stream:
  if name in json.load(stream):
    sys.exit('"%s" is already mapped' % label)
print("%s\t%s" % (name, label))
RESOLVE
  )"; then
    warn "Not recorded."
  else
    name="${chosen%%$'\t'*}"
    label="${chosen#*$'\t'}"
    ask "Now select \"$label\" in Nothing X, close the app, then press enter."

    /usr/bin/python3 "$HELPER" read-eq > "$EQREAD" 2>/dev/null &
    eq_job=$!
    start_spinner "Reading the equaliser"
    wait "$eq_job"
    eq_rc=$?
    stop_spinner

    if [[ $eq_rc -ne 0 ]]; then
      oops "Could not read the equaliser value. Is Nothing X closed?"
    elif ! /usr/bin/python3 - "$MAPPINGS" "$name" "$label" "$(cat "$EQREAD")" <<'STORE'
import json
import sys

path, name, label, payload = sys.argv[1:]
result = json.loads(payload)
raw = result.get("eq", {}).get("raw")
if not result.get("ok") or not isinstance(raw, int):
  sys.exit("the helper did not return a usable equaliser id")
with open(path, "r+", encoding="utf-8") as stream:
  mappings = json.load(stream)
  if any(entry["id"] == raw for entry in mappings.values()):
    sys.exit("id %d is already mapped; was a different preset selected?" % raw)
  mappings[name] = {"id": raw, "label": label}
  stream.seek(0)
  json.dump(mappings, stream, sort_keys=True)
  stream.truncate()
print('Recorded "%s" as id %d.' % (label, raw))
STORE
    then
      warn "Not recorded."
    fi
  fi
  ask "Map another preset? [y/N]"
  reply="$REPLY_TEXT"
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
    stream.write("| Nothing X label | Key | Raw EQ id |\n| --- | --- | --- |\n")
    for name, entry in sorted(mappings.items()):
      stream.write(f"| {entry['label']} | `{name}` | `{entry['id']}` |\n")
    stream.write("\nThe values above were selected in Nothing X, then read after closing it.\n")
  else:
    stream.write("No equaliser presets were verified in this run.\n")
PY

heading "Report"
printf '\n%s\n' "$(cat "$REPORT")"
printf '\n%s---%s\n' "$C_DIM" "$C_RESET"
note "Saved to: $REPORT"
if command -v wl-copy >/dev/null 2>&1; then
  wl-copy < "$REPORT" && good "Copied to the clipboard"
fi

if [[ $(/usr/bin/python3 - "$MAPPINGS" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
  print("yes" if json.load(stream) else "no")
PY
) == "yes" ]]; then
  printf '\n'
  ask "Apply the confirmed EQ mapping as a local hotfix? [y/N]"
  reply="$REPLY_TEXT"
  hotfix_rc=0
  if [[ ${reply,,} == "y" ]]; then
    /usr/bin/python3 - "$STATUS" "$MAPPINGS" \
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
  print("%s is already verified; a local hotfix would only narrow it"
        % (model.get("name") or name), file=sys.stderr)
  sys.exit(3)
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
  "eq": {name: entry["id"] for name, entry in mappings.items()},
  "eq_labels": {name: entry["label"] for name, entry in mappings.items()},
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
    hotfix_rc=$?
    if [[ $hotfix_rc -eq 0 ]]; then
      good "Local hotfix saved. Reopen the panel to load the confirmed EQ controls."
    elif [[ $hotfix_rc -eq 3 ]]; then
      note "No hotfix needed, for the reason above."
    else
      warn "Could not save the local hotfix."
    fi
  fi
else
  note "No EQ mappings were confirmed, so no local hotfix is available."
fi

TITLE="Device support: $(sed -n 's/^| Bluetooth name | `\(.*\)` |$/\1/p' "$REPORT" | head -1)"

printf '\n'
warn "Read the report above before sending it. It contains your device state."

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ask "Open an issue on $REPO as $(gh api user --jq .login 2>/dev/null)? [y/N]"
  if [[ ${REPLY_TEXT,,} == "y" ]]; then
    gh issue create --repo "$REPO" --title "$TITLE" --body-file "$REPORT" \
      && good "Thank you. That is enough to map the device."
  else
    note "Nothing sent. The report is still at $REPORT"
  fi
else
  note "GitHub CLI is not set up, so nothing can be posted from here."
  note "Open an issue and paste the report (it is on your clipboard):"
  note "  https://github.com/$REPO/issues/new"
fi

printf '\n'
ask "Press enter to close."
