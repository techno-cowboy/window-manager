#!/bin/zsh
# Builds "Window Manager.app" into ./build.
#   ./build.sh            build only
#   ./build.sh install    build, copy to /Applications and launch
#
# Signing: set CODESIGN_IDENTITY to a stable certificate (e.g. "Apple Development: …")
# so the Accessibility permission survives rebuilds. Without it the app is signed
# ad-hoc and macOS asks for the permission again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Window Manager"
BUNDLE_ID="com.nilsmontag.WindowManager"
APP="build/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/WindowManager"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || assets/icon.svg -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift assets/icon.svg build/AppIcon.iconset \
    && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns \
    || echo "⚠︎ Icon konnte nicht erzeugt werden – baue ohne Icon weiter."
fi
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "✓ Gebaut: $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x WindowManager 2>/dev/null && sleep 0.5 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/"
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    # Ad-hoc signature changed → the old Accessibility entry no longer matches.
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  open "/Applications/$APP_NAME.app"
  echo "✓ Installiert und gestartet: /Applications/$APP_NAME.app"
fi
