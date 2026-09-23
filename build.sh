#!/bin/bash
# Builds Markpad.app into ./build. Requires the Xcode command line tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Markpad.app"
DEPLOY_TARGET="13.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=("$ROOT"/Sources/*.swift)

# --- icon -------------------------------------------------------------------
ICONSET="$BUILD/AppIcon.iconset"
if xcrun swift "$ROOT/tools/MakeIcon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    rm -rf "$ICONSET"
else
    echo "note: icon generation skipped (app will use the generic icon)"
fi

# --- compile ----------------------------------------------------------------
ARCHS=()
for ARCH in arm64 x86_64; do
    if xcrun swiftc -sdk "$SDK" -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
        -module-name Markpad -O -whole-module-optimization -swift-version 5 \
        -o "$BUILD/markpad-$ARCH" "${SOURCES[@]}" 2>"$BUILD/build-$ARCH.log"; then
        ARCHS+=("$BUILD/markpad-$ARCH")
    else
        if [ "$ARCH" = "arm64" ] && [ "$(uname -m)" != "arm64" ]; then
            echo "note: skipping arm64 slice"
        elif [ "$ARCH" = "x86_64" ] && [ "$(uname -m)" = "arm64" ]; then
            echo "note: skipping x86_64 slice"
        else
            cat "$BUILD/build-$ARCH.log" >&2
            exit 1
        fi
    fi
done

if [ ${#ARCHS[@]} -eq 0 ]; then
    echo "error: no architecture built" >&2
    exit 1
fi
lipo -create "${ARCHS[@]}" -output "$APP/Contents/MacOS/Markpad"
rm -f "${ARCHS[@]}" "$BUILD"/build-*.log

# --- bundle -----------------------------------------------------------------
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "note: ad-hoc code signing failed; the app will still run locally"

echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/Markpad"))"
