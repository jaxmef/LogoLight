#!/bin/zsh
# ./release.sh <version> → dist/: zip, dmg and SHA256SUMS.txt for a GitHub release.
# Set SIGN_IDENTITY (see README) so the audio permission survives updates.
set -eu
cd "${0:A:h}"
export VERSION="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.0.0}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "release.sh: version must look like 1.2.3 (got '$VERSION')" >&2; exit 1; }
export BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%m%d.%H%M%S)}"   # always increases
[[ "${SIGN_IDENTITY:--}" == "-" ]] && echo "note: SIGN_IDENTITY not set, building ad-hoc signed" >&2
./build.sh

# Only replace dist/ once everything succeeded.
WORK="$(mktemp -d)"
MNT=""
trap '[[ -n "$MNT" && -d "$MNT" ]] && hdiutil detach -quiet -force "$MNT"; rm -rf "$WORK"' EXIT
OUTDIR="$WORK/out"; STAGE="$WORK/stage"
mkdir -p "$OUTDIR" "$STAGE"
ditto -c -k --keepParent build/LogoLight.app "$OUTDIR/LogoLight-$VERSION.zip"
cp -R build/LogoLight.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The Finder window layout lives in the volume's .DS_Store, so build a writable image and let Finder arrange it.
# Needs a desktop session; macOS asks once to let the terminal control Finder.
hdiutil create -quiet -volname "LogoLight $VERSION" -srcfolder "$STAGE" -format UDRW -ov "$WORK/rw.dmg"
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')"
osascript <<OSA
tell application "Finder"
  tell disk "${MNT:t}"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set bounds to {200, 120, 740, 420}
    end tell
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set position of item "LogoLight.app" of container window to {140, 120}
    set position of item "Applications" of container window to {400, 120}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
# After Finder: it removes the volume icon while saving the layout.
cp build/LogoLight.app/Contents/Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
rm -rf "$MNT/.fseventsd"
sync
for attempt in 1 2 3 4 5; do hdiutil detach -quiet "$MNT" && break; sleep 1; done
[[ ! -d "$MNT" ]] || { echo "release.sh: couldn't unmount $MNT" >&2; exit 1; }
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -o "$OUTDIR/LogoLight-$VERSION.dmg"
(cd "$OUTDIR" && shasum -a 256 "LogoLight-$VERSION.zip" "LogoLight-$VERSION.dmg" > SHA256SUMS.txt)

rm -rf dist
mv "$OUTDIR" dist
echo "release $VERSION ($BUILD_NUMBER) in $PWD/dist:"; ls -l dist
