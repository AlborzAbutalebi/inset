#!/bin/zsh
# Builds Inset.app (Apple Silicon, release) into ./build.
#   ./scripts/build.sh            build + sign
#   ./scripts/build.sh --install  also copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Inset.app
echo "› Compiling (release, arm64)…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Inset"

echo "› Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Inset"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "› Rendering icon…"
  swift scripts/make_icon.swift build/AppIcon.iconset >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development identity if you have one (keeps privacy permissions
# stable across rebuilds); otherwise fall back to ad-hoc signing.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  echo "› Signing with: $IDENTITY"
  codesign --force --options runtime --entitlements Resources/Inset.entitlements --sign "$IDENTITY" "$APP"
else
  echo "› Signing ad-hoc"
  codesign --force --entitlements Resources/Inset.entitlements --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "› Installing to /Applications"
  rm -rf /Applications/Inset.app
  cp -R "$APP" /Applications/
  echo "✓ /Applications/Inset.app"
else
  echo "✓ $APP"
fi
