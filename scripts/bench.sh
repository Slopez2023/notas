#!/bin/zsh
# Times the writing-path hot spots in a release build. Usage: scripts/bench.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] && export SDKROOT="$SDK"
swift build -c release -Xswiftc -DBENCH 2>&1 | grep -E "error|warning: unused|Compiling|Build" | tail -5
"$(swift build -c release --show-bin-path)/Notas" --bench
