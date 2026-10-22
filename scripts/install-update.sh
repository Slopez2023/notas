#!/bin/zsh
set -euo pipefail

APP_PID="$1"
SOURCE="$2"
DESTINATION="$3"
STAGED="$4"
BACKUP="$5"
WORK_ROOT="$6"

[[ "$SOURCE" == */Notas.app && "$DESTINATION" == */Notas.app ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" == "com.stephenlopez.notas" ]] || exit 3

for _ in {1..600}; do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$APP_PID" 2>/dev/null; then
  /bin/rm -rf "$WORK_ROOT"
  exit 4
fi

/usr/bin/ditto "$SOURCE" "$STAGED"
/usr/bin/codesign --verify --deep --strict "$STAGED"

if [[ -e "$DESTINATION" ]]; then
  /bin/mv "$DESTINATION" "$BACKUP"
fi

if ! /bin/mv "$STAGED" "$DESTINATION"; then
  [[ -e "$BACKUP" && ! -e "$DESTINATION" ]] && /bin/mv "$BACKUP" "$DESTINATION"
  exit 5
fi

/usr/bin/xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true
/usr/bin/open "$DESTINATION"
/bin/rm -rf "$BACKUP" "$WORK_ROOT"
