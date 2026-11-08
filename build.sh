#!/bin/zsh
# Builds build/LogoLight.app and build/logoctl.
# Optional: VERSION (default: latest release tag), BUILD_NUMBER (default 1), SIGN_IDENTITY (default "-" = ad-hoc).
set -eu
cd "${0:A:h}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"   # not a git checkout, or no tags fetched
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "build.sh: VERSION must look like 1.2.3 (got '$VERSION')" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "build.sh: BUILD_NUMBER must look like 42 or 1.2.3 (got '$BUILD_NUMBER')" >&2; exit 1; }
# Prefer the Command Line Tools: they don't need the Xcode license accepted.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
OUT=build
rm -rf "$OUT/LogoLight.app"
mkdir -p "$OUT/LogoLight.app/Contents/MacOS" "$OUT/LogoLight.app/Contents/Resources"
cp "$BIN/logoctl" "$OUT/logoctl"
cp "$BIN/LogoLight" "$OUT/LogoLight.app/Contents/MacOS/LogoLight"

ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/LogoLight.app/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cp LICENSE "$OUT/LogoLight.app/Contents/Resources/LICENSE"
cat > "$OUT/LogoLight.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.jaxmef.LogoLight</string>
  <key>CFBundleName</key><string>LogoLight</string>
  <key>CFBundleExecutable</key><string>LogoLight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 jaxmef. MIT License.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>27.2</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>LogoLight listens to what your Mac is playing to pulse the Apple logo with the music. Audio is analysed on the fly for loudness only; nothing is recorded or saved.</string>
</dict></plist>
PLIST
plutil -lint -s "$OUT/LogoLight.app/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" "$OUT/logoctl"
codesign --force --sign "$SIGN_IDENTITY" "$OUT/LogoLight.app"
codesign --verify --strict "$OUT/logoctl"
codesign --verify --strict --deep "$OUT/LogoLight.app"
echo "built $VERSION ($BUILD_NUMBER), signed with ${SIGN_IDENTITY/#-/ad-hoc}: $PWD/$OUT/logoctl and $PWD/$OUT/LogoLight.app"
