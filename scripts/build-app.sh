#!/bin/zsh
# Builds dist/Claude Profiles.app from gui/Claude Profiles.applescript.
#
#   zsh scripts/build-app.sh
#   VERSION=1.2.3 zsh scripts/build-app.sh      override the version (default: ./VERSION, else 0.1.0)
#   ICON_HUE=190 zsh scripts/build-app.sh       hue shift in degrees for the app icon
#
# The icon is derived from /Applications/Claude.app when it exists; otherwise the
# default applet icon is kept. bin/ and lib/ are copied into Contents/Resources/, and
# the version into Contents/Resources/VERSION (where the bundled CLI reads it).
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
APP="$DIST/Claude Profiles.app"
SOURCE_SCRIPT="$ROOT/gui/Claude Profiles.applescript"
SOURCE_ICNS="${SOURCE_ICNS:-/Applications/Claude.app/Contents/Resources/electron.icns}"
TINT_SCRIPT="${TINT_SCRIPT:-$ROOT/lib/tint.js}"
ICON_HUE="${ICON_HUE:-190}"
BUNDLE_ID="io.github.claude-desktop-profiles.app"
PB=/usr/libexec/PlistBuddy

die()  { print -u2 "ERROR: $*"; exit 1; }
warn() { print -u2 "WARN:  $*"; }

read_version() {
  local from_file=""
  [[ -r $ROOT/VERSION ]] && from_file=$(<"$ROOT/VERSION")
  from_file=${from_file//[[:space:]]/}
  print -r -- "${VERSION:-${from_file:-0.1.0}}"
}

plist_set() {
  local plist=$1 key=$2 value=$3
  $PB -c "Set :$key $value" "$plist" 2>/dev/null || $PB -c "Add :$key string $value" "$plist"
}

build_icon() {
  local work=$1 icns_out=$2
  [[ -f $SOURCE_ICNS && -f $TINT_SCRIPT ]] || return 1
  iconutil -c iconset "$SOURCE_ICNS" -o "$work/icon.iconset" >/dev/null 2>&1 || return 1
  local png
  for png in "$work"/icon.iconset/*.png; do
    osascript -l JavaScript "$TINT_SCRIPT" "$png" "$ICON_HUE" 1 >/dev/null 2>&1 || return 1
  done
  iconutil -c icns "$work/icon.iconset" -o "$icns_out" >/dev/null 2>&1
}

[[ -f $SOURCE_SCRIPT ]] || die "Missing $SOURCE_SCRIPT"
VERSION_STRING=$(read_version)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$DIST"
rm -rf "$APP"
osacompile -o "$APP" "$SOURCE_SCRIPT"

RESOURCES="$APP/Contents/Resources"
for folder in bin lib; do
  if [[ -d $ROOT/$folder ]]; then
    ditto "$ROOT/$folder" "$RESOURCES/$folder"
  else
    warn "$ROOT/$folder not found: the app will be built without it"
  fi
done
[[ -f $RESOURCES/bin/claude-profiles ]] && chmod +x "$RESOURCES/bin/claude-profiles"
print -r -- "$VERSION_STRING" > "$RESOURCES/VERSION"

PLIST="$APP/Contents/Info.plist"
plist_set "$PLIST" CFBundleIdentifier "$BUNDLE_ID"
plist_set "$PLIST" CFBundleName "Claude Profiles"
plist_set "$PLIST" CFBundleDisplayName "Claude Profiles"
plist_set "$PLIST" CFBundleShortVersionString "$VERSION_STRING"
plist_set "$PLIST" CFBundleVersion "$VERSION_STRING"

if build_icon "$WORK" "$WORK/applet.icns"; then
  cp "$WORK/applet.icns" "$RESOURCES/applet.icns"
  $PB -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
  rm -f "$RESOURCES/Assets.car"
  print "Icon: tinted from $SOURCE_ICNS (hue $ICON_HUE)"
else
  print "Icon: default applet icon ($SOURCE_ICNS or $TINT_SCRIPT unavailable, or tinting failed)"
fi

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"

print "Built: $APP (version $VERSION_STRING)"
