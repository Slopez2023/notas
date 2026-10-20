#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] && export SDKROOT="$SDK"
swift build
BIN="$(swift build --show-bin-path)/Notas"
"$BIN" --assistant-test
if [[ "${1:-}" == "--live" ]]; then
  "$BIN" --check-codex
fi
