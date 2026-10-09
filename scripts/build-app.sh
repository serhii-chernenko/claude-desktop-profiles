#!/bin/zsh
# Builds dist/Claude Profiles.app, the native SwiftUI app, as a universal binary.
#
#   zsh scripts/build-app.sh
#   VERSION=1.2.3 zsh scripts/build-app.sh          override the version (default: ./VERSION, else 0.1.0)
#   SIGNING_IDENTITY="Name" zsh scripts/build-app.sh sign with a certificate instead of ad-hoc
#
# bin/, lib/ and the version are copied into Contents/Resources/cli/, where the app runs the CLI.
# The native architecture runs --self-test against a temporary CLAUDE_PROFILES_HOME.
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
APP_NAME="Claude Profiles"
APP="$DIST/$APP_NAME.app"
EXECUTABLE=ClaudeProfiles
BUNDLE_ID="io.github.claude-desktop-profiles.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
PB=/usr/libexec/PlistBuddy

die() { print -u2 "ERROR: $*"; exit 1; }

read_version() {
  local from_file=""
  [[ -r $ROOT/VERSION ]] && from_file=$(<"$ROOT/VERSION")
  from_file=${from_file//[[:space:]]/}
  print -r -- "${VERSION:-${from_file:-0.1.0}}"
}

[[ $(uname -s) == Darwin ]] || die "Build on macOS with the Xcode Command Line Tools installed."
for folder in bin lib; do
  [[ -d $ROOT/$folder ]] || die "Missing $ROOT/$folder"
done

VERSION_STRING=$(read_version)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$APP_NAME.app"
CONTENTS="$STAGE/Contents"
CLI_DIR="$CONTENTS/Resources/cli"

mkdir -p "$CONTENTS/MacOS" "$CLI_DIR"
cp -X "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION_STRING" "$CONTENTS/Info.plist"
$PB -c "Set :CFBundleVersion $VERSION_STRING" "$CONTENTS/Info.plist"

sdk=$(xcrun --sdk macosx --show-sdk-path)
sources=( "$ROOT"/Sources/ClaudeProfiles/*.swift )
for arch in arm64 x86_64; do
  print "Compiling $arch..."
  xcrun swiftc -O -sdk "$sdk" -target "$arch-apple-macos13.0" \
    -framework AppKit -framework SwiftUI \
    "${sources[@]}" -o "$WORK/$EXECUTABLE-$arch"
done
lipo -create "$WORK/$EXECUTABLE-arm64" "$WORK/$EXECUTABLE-x86_64" -output "$CONTENTS/MacOS/$EXECUTABLE"

ditto --noqtn "$ROOT/bin" "$CLI_DIR/bin"
ditto --noqtn "$ROOT/lib" "$CLI_DIR/lib"
print -r -- "$VERSION_STRING" > "$CLI_DIR/VERSION"
chmod +x "$CLI_DIR/bin/claude-profiles"

iconset="$WORK/AppIcon.iconset"
mkdir -p "$iconset"
xcrun swift "$ROOT/scripts/make-icon.swift" "$WORK/icon-1024.png"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$WORK/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$(( size * 2 ))
  sips -s format png -z "$double" "$double" "$WORK/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$CONTENTS/Resources/AppIcon.icns"

xattr -cr "$STAGE"
codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$STAGE"
codesign --verify --deep --strict "$STAGE"

print "Running the self-test ($(uname -m))..."
"$CONTENTS/MacOS/$EXECUTABLE" --self-test

mkdir -p "$DIST"
rm -rf "$APP"
ditto "$STAGE" "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"

print "Built: $APP (version $VERSION_STRING, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
