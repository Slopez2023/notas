#!/bin/zsh
# Replaces Notas.app once the running app has quit, then reopens it.
# Args: APP_PID SOURCE DESTINATION STAGED BACKUP WORK_ROOT
set -euo pipefail

APP_PID="${1:-}"
SOURCE="${2:-}"
DESTINATION="${3:-}"
STAGED="${4:-}"
BACKUP="${5:-}"
WORK_ROOT="${6:-}"
OPEN="${NOTAS_OPEN_COMMAND:-/usr/bin/open}"
inputs=0
installed=0
rollback=1

wait_for_quit() {
  for _ in {1..600}; do
    kill -0 "$APP_PID" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

finish() {
  local code=$?
  trap - EXIT
  if (( ! installed && rollback && inputs )) && wait_for_quit; then
    if [[ ! -e "$DESTINATION" && -e "$BACKUP" ]]; then
      /bin/mv "$BACKUP" "$DESTINATION" || echo "Notas could not be restored. The previous app is at $BACKUP" >&2
    fi
    if [[ -e "$DESTINATION" ]]; then
      "$OPEN" "$DESTINATION" || true
    fi
  fi
  if (( inputs )); then
    /bin/rm -rf "$STAGED" "$WORK_ROOT"
  fi
  exit $code
}
trap finish EXIT

[[ $# -eq 6 && "$APP_PID" =~ ^[0-9]+$ ]] || exit 2
[[ "$SOURCE" == */Notas.app && "$DESTINATION" == */Notas.app ]] || exit 2
[[ "$WORK_ROOT" == */Notas-update-* ]] || exit 2
[[ "$STAGED" == "$(dirname "$DESTINATION")"/.Notas-update-*.app ]] || exit 2
[[ "$BACKUP" == "$(dirname "$DESTINATION")"/.Notas-backup-*.app ]] || exit 2
[[ -w "$(dirname "$DESTINATION")" ]] || exit 2
inputs=1
[[ -d "$SOURCE" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist" 2>/dev/null || true)" == "com.stephenlopez.notas" ]] || exit 3

/usr/bin/ditto "$SOURCE" "$STAGED"
/usr/bin/codesign --verify --deep --strict "$STAGED"

wait_for_quit || { rollback=0; exit 4; }

if [[ -e "$DESTINATION" ]]; then
  /bin/mv "$DESTINATION" "$BACKUP"
fi
/bin/mv "$STAGED" "$DESTINATION"
installed=1

/usr/bin/xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true
/bin/rm -rf "$BACKUP" "$WORK_ROOT" 2>/dev/null || true
"$OPEN" "$DESTINATION" || true
