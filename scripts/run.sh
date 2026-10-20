#!/bin/zsh
# Builds and launches Notas. Pass NOTAS_LIBRARY=/some/dir to use a scratch library.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh debug
pkill -x Notas 2>/dev/null || true
if [[ -n "${NOTAS_LIBRARY:-}" ]]; then
  NOTAS_LIBRARY="$NOTAS_LIBRARY" build/Notas.app/Contents/MacOS/Notas &
else
  open build/Notas.app
fi
