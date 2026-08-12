#!/bin/zsh
# NetSpeed — build script. Produces build/NetSpeed.app.
#
# The engine (official Ookla Speedtest CLI) is downloaded from Ookla's
# servers on first build and embedded into the app bundle. It is NOT
# part of this repository — Ookla's license does not allow redistribution.
# By building you accept Ookla's terms: https://www.speedtest.net/about/eula
set -euo pipefail
cd "$(dirname "$0")"

ENGINE_VERSION="1.2.0"
ENGINE_URL="https://install.speedtest.net/app/cli/ookla-speedtest-${ENGINE_VERSION}-macosx-universal.tgz"

if [ ! -x speedtest ] || ! ./speedtest --version 2>/dev/null | grep -q "Speedtest by Ookla"; then
    echo "==> Fetching official Ookla Speedtest CLI ${ENGINE_VERSION}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/ookla.tgz" "$ENGINE_URL"
    tar xzf "$tmp/ookla.tgz" -C . speedtest
    rm -rf "$tmp"
    chmod +x speedtest
fi
echo "==> Engine: $(./speedtest --version | head -1)"

APP=build/NetSpeed.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
swiftc -O -parse-as-library Sources/main.swift -o "$APP/Contents/MacOS/NetSpeed"

cp Info.plist "$APP/Contents/Info.plist"

# The app carries its own source, so an installed copy is always rebuildable.
cp Sources/main.swift "$APP/Contents/Resources/main.swift"
cp Info.plist "$APP/Contents/Resources/Info.plist.src"
cp build.sh "$APP/Contents/Resources/build.sh"

# Bundled engine (keeps Ookla's own code signature).
cp -X speedtest "$APP/Contents/Resources/speedtest"
chmod +x "$APP/Contents/Resources/speedtest"

codesign --force --sign - "$APP"
echo "==> BUILD OK: $APP"
