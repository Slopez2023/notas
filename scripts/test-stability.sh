#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] && export SDKROOT="$SDK"
swift build
env -u OPENCODE_API_KEY "$(swift build --show-bin-path)/Notas" --stability-test
python3 scripts/check-xcode-sources.py
