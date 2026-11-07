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
trap 'rm -rf "$WORK"' EXIT
OUTDIR="$WORK/out"; STAGE="$WORK/stage"
mkdir -p "$OUTDIR" "$STAGE"
ditto -c -k --keepParent build/LogoLight.app "$OUTDIR/LogoLight-$VERSION.zip"
cp -R build/LogoLight.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "LogoLight $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUTDIR/LogoLight-$VERSION.dmg"
(cd "$OUTDIR" && shasum -a 256 "LogoLight-$VERSION.zip" "LogoLight-$VERSION.dmg" > SHA256SUMS.txt)

rm -rf dist
mv "$OUTDIR" dist
echo "release $VERSION ($BUILD_NUMBER) in $PWD/dist:"; ls -l dist
