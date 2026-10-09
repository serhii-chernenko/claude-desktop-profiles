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
ditto "$APP" "$STAGE/Claude Profiles.app"
ln -s /Applications "$STAGE/Applications"
if [[ -f $ROOT/README.md ]]; then
  cp "$ROOT/README.md" "$STAGE/README.md"
else
  print -u2 "WARN:  README.md not found: the DMG is built without it"
fi

rm -f "$DMG"
attempt=1
until hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; do
  (( attempt >= 3 )) && die "hdiutil create failed after $attempt attempts"
  attempt=$(( attempt + 1 ))
  sleep 3
done

hdiutil verify "$DMG" >/dev/null
print "Built: $DMG"
