#!/bin/bash
# Installs the latest Notas release into ~/Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/Slopez2023/notas/main/scripts/install.sh | bash
set -euo pipefail

REPO="Slopez2023/notas"
DEST="$HOME/Applications"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || { echo "Notas needs an Apple Silicon Mac." >&2; exit 1; }
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]] || { echo "Notas needs macOS 26 or newer." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Notas..."
curl -fsSL "https://github.com/$REPO/releases/latest/download/Notas.app.zip" -o "$TMP/Notas.app.zip"

if pgrep -x Notas >/dev/null; then
  echo "Quit Notas first, then run this again." >&2
  exit 1
fi

mkdir -p "$DEST"
rm -rf "$DEST/Notas.app"
ditto -x -k "$TMP/Notas.app.zip" "$DEST"
xattr -dr com.apple.quarantine "$DEST/Notas.app" 2>/dev/null || true

echo "Installed to $DEST/Notas.app"
open "$DEST/Notas.app"
