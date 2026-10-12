#!/bin/zsh
# Builds dist/Claude Profiles.app, the native SwiftUI app, as a universal binary.
#
#   zsh scripts/build-app.sh
#   VERSION=1.2.3 zsh scripts/build-app.sh          override the version (default: ./VERSION, else 0.1.0)
#   SIGNING_IDENTITY="Name" zsh scripts/build-app.sh sign with this certificate (SIGNING_IDENTITY=- forces ad-hoc)
#
# Without SIGNING_IDENTITY the app is signed with "Claude Profiles Signing" when that certificate is in the
# login keychain and a non-interactive test signature works; otherwise it falls back to ad-hoc with a warning.
# A stable identity keeps the designated requirement the same across builds, so macOS privacy grants survive.
#
# bin/, lib/ and the version are copied into Contents/Resources/cli/, where the app runs the CLI.
# Sparkle 2 is downloaded and checksum-verified by scripts/fetch-sparkle.sh, embedded in
# Contents/Frameworks and signed inside-out (XPC services, Autoupdate, Updater.app, framework, app).
# CFBundleVersion is major*10000 + minor*100 + patch of the version, so it only ever increases.
# The native architecture runs --self-test against a temporary CLAUDE_PROFILES_HOME.
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
APP_NAME="Claude Profiles"
APP="$DIST/$APP_NAME.app"
EXECUTABLE=ClaudeProfiles
BUNDLE_ID="io.github.claude-desktop-profiles.app"
PB=/usr/libexec/PlistBuddy

die() { print -u2 "ERROR: $*"; exit 1; }

source "$ROOT/scripts/signing-identity.sh"

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

bundle_build_number() {
  local core=${1%%[-+]*}
  [[ $core =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]] || die "The version must look like 1.2.3 (got \"$1\")."
  local major=$match[1] minor=$match[2] patch=$match[3]
  (( minor < 100 && patch < 100 )) || die "Minor and patch versions must stay below 100 (got \"$1\")."
  print -r -- $(( major * 10000 + minor * 100 + patch ))
}

SIGN_IDENTITY=$(resolve_signing_identity)
SIGN_TIMESTAMP_ARGS=()
if [[ $SIGN_IDENTITY == - ]]; then
  print -u2 "WARN: signing ad-hoc. macOS privacy grants such as Accessibility stop matching after every rebuild or update."
  print -u2 "WARN: create the \"$DEFAULT_SIGNING_IDENTITY\" identity with bin/claude-profiles setup, or set SIGNING_IDENTITY."
  print "Signing identity: ad-hoc"
else
  identity_can_sign "$SIGN_IDENTITY" || die "codesign cannot sign with \"$SIGN_IDENTITY\" without a prompt: the certificate is missing, or the login keychain is locked. Run bin/claude-profiles setup."
  identity_is_self_signed "$SIGN_IDENTITY" && SIGN_TIMESTAMP_ARGS=(--timestamp=none)
  print "Signing identity: $SIGN_IDENTITY (SHA-1 $(identity_sha1 "$SIGN_IDENTITY"))"
fi

sign_bundle() {
  codesign --force --sign "$SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" "$@"
}

VERSION_STRING=$(read_version)
BUILD_NUMBER=$(bundle_build_number "$VERSION_STRING")
SPARKLE_DIR=$("$ROOT/scripts/fetch-sparkle.sh")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$APP_NAME.app"
CONTENTS="$STAGE/Contents"
CLI_DIR="$CONTENTS/Resources/cli"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CLI_DIR"
cp -X "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION_STRING" "$CONTENTS/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"

mkdir -p "$CONTENTS/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
cp "$SPARKLE_DIR/LICENSE" "$CONTENTS/Resources/Sparkle-LICENSE.txt"

sdk=$(xcrun --sdk macosx --show-sdk-path)
sources=( "$ROOT"/Sources/ClaudeProfiles/*.swift )
for arch in arm64 x86_64; do
  print "Compiling $arch..."
  xcrun swiftc -O -sdk "$sdk" -target "$arch-apple-macos13.0" \
    -F "$SPARKLE_DIR" -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework AppKit -framework SwiftUI -framework Sparkle \
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
SPARKLE_B="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
sign_bundle --preserve-metadata=entitlements "$SPARKLE_B/XPCServices/Downloader.xpc"
sign_bundle --preserve-metadata=entitlements "$SPARKLE_B/XPCServices/Installer.xpc"
sign_bundle "$SPARKLE_B/Autoupdate"
sign_bundle "$SPARKLE_B/Updater.app"
sign_bundle "$CONTENTS/Frameworks/Sparkle.framework"
sign_bundle --identifier "$BUNDLE_ID" "$STAGE"
codesign --verify --deep --strict "$STAGE"

print "Running the self-test ($(uname -m))..."
"$CONTENTS/MacOS/$EXECUTABLE" --self-test

mkdir -p "$DIST"
rm -rf "$APP"
ditto "$STAGE" "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"

print "Built: $APP (version $VERSION_STRING, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
