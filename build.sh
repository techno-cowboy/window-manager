#!/bin/zsh
# Builds "Window Manager.app" into ./build.
#   ./build.sh            build for this Mac
#   ./build.sh install    build, copy to /Applications and launch
#   ./build.sh release    universal build (Apple Silicon + Intel), zipped for a GitHub release
#
# Signing: set CODESIGN_IDENTITY to a stable certificate (e.g. "Apple Development: …")
# so the Accessibility permission survives rebuilds. Without it the app is signed
# ad hoc and macOS asks for the permission again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Window Manager"
BUNDLE_ID="com.nilsmontag.WindowManager"
APP="build/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"
MODE="${1:-}"

ARCH_FLAGS=()
[[ "$MODE" == "release" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/WindowManager"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || assets/icon.svg -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift assets/icon.svg build/AppIcon.iconset \
    && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns \
    || echo "⚠︎ Could not create the icon, continuing without it."
fi
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "✓ Built: $APP ($(lipo -archs "$APP/Contents/MacOS/WindowManager"))"

case "$MODE" in
  install)
    # Match the full path: macOS has its own process called "WindowManager" (Stage Manager).
    pkill -f "$INSTALLED/Contents/MacOS/WindowManager" 2>/dev/null && sleep 0.5 || true
    rm -rf "$INSTALLED"
    cp -R "$APP" /Applications/
    if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
      # Ad-hoc signature changed → the old Accessibility entry no longer matches.
      tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    open "$INSTALLED"
    echo "✓ Installed and launched: $INSTALLED"
    ;;
  release)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
    ZIP="build/Window-Manager-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "✓ Release archive: $ZIP"
    ;;
esac
