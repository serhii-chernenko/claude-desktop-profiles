#!/bin/zsh
# Builds dist/Claude-Profiles-<version>.dmg containing the app, an /Applications
# symlink and README.md. Runs scripts/build-app.sh first unless the app already exists
# and SKIP_APP_BUILD=1.
#
#   zsh scripts/build-dmg.sh
#   VERSION=1.2.3 zsh scripts/build-dmg.sh
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
APP="$DIST/Claude Profiles.app"
VOLUME_NAME="Claude Profiles"

die()  { print -u2 "ERROR: $*"; exit 1; }

read_version() {
  local from_file=""
  [[ -r $ROOT/VERSION ]] && from_file=$(<"$ROOT/VERSION")
  from_file=${from_file//[[:space:]]/}
  print -r -- "${VERSION:-${from_file:-0.1.0}}"
}

VERSION_STRING=$(read_version)
DMG="$DIST/Claude-Profiles-$VERSION_STRING.dmg"

if [[ ${SKIP_APP_BUILD:-0} != 1 || ! -d $APP ]]; then
  VERSION=$VERSION_STRING zsh "$ROOT/scripts/build-app.sh"
fi
[[ -d $APP ]] || die "Missing $APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -RX "$APP" "$STAGE/Claude Profiles.app"
xattr -cr "$STAGE/Claude Profiles.app"
codesign --verify --deep --strict "$STAGE/Claude Profiles.app" || die "the staged app fails its signature check"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TEXT'
1. Drag "Claude Profiles.app" to Applications. Do not run it from this disk image.
2. Open it from Applications. macOS blocks the first launch because the app is
   ad-hoc signed and not notarized:
   - open System Settings > Privacy & Security, scroll to Security and click
     "Open Anyway" for Claude Profiles (available for about an hour after the
     blocked launch), then click "Open" and enter your password if asked;
   - right-click > Open no longer bypasses this on macOS 15 and later.
3. Full guide: https://github.com/serhii-chernenko/claude-desktop-profiles#readme
TEXT
if [[ -f $ROOT/README.md ]]; then
  cp -X "$ROOT/README.md" "$STAGE/README.md"
else
  print -u2 "WARN:  README.md not found: the DMG is built without it"
fi

rm -f "$DMG"
attempt=1
until hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null; do
  (( attempt >= 3 )) && die "hdiutil create failed after $attempt attempts"
  attempt=$(( attempt + 1 ))
  sleep 3
done

hdiutil verify "$DMG" >/dev/null
(cd "$DIST" && shasum -a 256 "${DMG:t}" > SHA256SUMS.txt)
print "Built: $DMG"
