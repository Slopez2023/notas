#!/bin/zsh
# Runs the headless self-test (codec, editor behavior, storage).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] && export SDKROOT="$SDK"
swift build
"$(swift build --show-bin-path)/Notas" --self-test
