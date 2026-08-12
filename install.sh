#!/bin/bash
# NetSpeed one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/ayyaninam/netspeed/main/install.sh | bash
# Downloads the source, builds it locally, installs to /Applications.
set -euo pipefail

REPO="ayyaninam/netspeed"

echo "==> NetSpeed installer"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "ERROR: Swift compiler not found."
    echo "Install Apple's Command Line Tools first, then re-run:"
    echo "    xcode-select --install"
    exit 1
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 13 ]; then
    echo "ERROR: macOS 13 (Ventura) or newer required — found $(sw_vers -productVersion)."
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading source (github.com/$REPO)"
curl -fsSL "https://github.com/$REPO/tarball/main" | tar xz -C "$TMP" --strip-components 1

echo "==> Building (fetches the official Ookla Speedtest CLI engine;"
echo "    by continuing you accept Ookla's EULA — https://www.speedtest.net/about/eula)"
cd "$TMP"
./build.sh

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

pkill -x NetSpeed 2>/dev/null || true
rm -rf "$DEST/NetSpeed.app"
cp -R build/NetSpeed.app "$DEST/"
open "$DEST/NetSpeed.app"

echo "==> Installed: $DEST/NetSpeed.app"
echo "    Look for the speedometer icon in your menu bar, click it, hit GO."
