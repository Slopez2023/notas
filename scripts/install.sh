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

ditto -x -k "$TMP/Notas.app.zip" "$TMP"
PLIST="$TMP/Notas.app/Contents/Info.plist"
[[ -f "$PLIST" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)" == "com.stephenlopez.notas" ]] \
  || { echo "The download is not a valid Notas app." >&2; exit 1; }

mkdir -p "$DEST"
PREVIOUS="$DEST/.Notas-previous-$$.app"
if [[ -e "$DEST/Notas.app" ]]; then
  mv "$DEST/Notas.app" "$PREVIOUS" || { echo "Could not move the existing Notas aside in $DEST." >&2; exit 1; }
fi
if ! mv "$TMP/Notas.app" "$DEST/Notas.app"; then
  if [[ -e "$PREVIOUS" ]]; then
    rm -rf "$DEST/Notas.app"
    mv "$PREVIOUS" "$DEST/Notas.app"
  fi
  echo "Could not install Notas to $DEST. Your previous copy was kept." >&2
  exit 1
fi
rm -rf "$PREVIOUS"
xattr -dr com.apple.quarantine "$DEST/Notas.app" 2>/dev/null || true

echo "Installed to $DEST/Notas.app"
if [[ "$DEST" == "$HOME/Applications" && -e /Applications/Notas.app ]]; then
  echo "An older copy is still in /Applications. Drag /Applications/Notas.app to the Trash."
fi
open "$DEST/Notas.app"
