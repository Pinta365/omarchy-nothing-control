#!/usr/bin/env bash
# Collect what an unverified device answers, so it can be mapped properly.
#
# Nothing here is sent anywhere on its own. The report is printed for you to
# read first, and only posted if you say so. The device-info block is redacted
# by the helper because it carries the serial number and Bluetooth address.
set -uo pipefail

REPO="Pinta365/omarchy-nothing-control"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$(mktemp -t nothing-control-report-XXXXXX.md)"

printf 'Probing the earbuds. This sweeps every read-only opcode and takes about a minute.\n\n'

if ! /usr/bin/python3 "$HERE/helper/nothing_ear.py" probe > "$REPORT" 2>&1; then
  printf 'The probe failed. Are the earbuds connected, and is the panel closed?\n'
  printf 'Only one program may hold the control channel at a time.\n\n'
  cat "$REPORT"
  read -rp 'Press enter to close. '
  exit 1
fi

printf '%s\n' "$(cat "$REPORT")"
printf '\n---\n\n'
printf 'Saved to: %s\n' "$REPORT"

if command -v wl-copy >/dev/null 2>&1; then
  wl-copy < "$REPORT" && printf 'Copied to the clipboard.\n'
fi

TITLE="Device support: $(sed -n 's/^| Bluetooth name | `\(.*\)` |$/\1/p' "$REPORT" | head -1)"

printf '\nRead the report above before sending it. It contains your device state.\n\n'

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  read -rp "Open an issue on $REPO as $(gh api user --jq .login 2>/dev/null)? [y/N] " reply
  if [[ ${reply,,} == y ]]; then
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
