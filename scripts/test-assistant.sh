#!/bin/zsh
# Headless assistant tests against a local stand-in for the model API (no key or network).
# With --live, sends one tiny real request using OPENCODE_API_KEY from .env.local.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] && export SDKROOT="$SDK"
swift build
BIN="$(swift build --show-bin-path)/Notas"
env -u OPENCODE_API_KEY "$BIN" --assistant-test
if [[ "${1:-}" == "--live" ]]; then
  set -a; source .env.local; set +a
  "$BIN" --assistant-test --live
fi
