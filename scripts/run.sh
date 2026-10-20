#!/bin/zsh
# Builds and launches Notas. Pass NOTAS_LIBRARY=/some/dir to use a scratch library.
# If .env.local defines OPENCODE_API_KEY, the app adopts it into the Keychain on first launch.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh debug
pkill -x Notas 2>/dev/null || true
[[ -f .env.local ]] && { set -a; source .env.local; set +a; }
if [[ -n "${NOTAS_LIBRARY:-}" ]]; then
  NOTAS_LIBRARY="$NOTAS_LIBRARY" build/Notas.app/Contents/MacOS/Notas &
elif [[ -n "${OPENCODE_API_KEY:-}" ]]; then
  build/Notas.app/Contents/MacOS/Notas &
else
  open build/Notas.app
fi
