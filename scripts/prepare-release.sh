#!/bin/zsh
# Builds and signs a release on the maintainer Mac. Never run by CI: the Ed25519 update
# signing key lives in the login keychain.
#
#   zsh scripts/prepare-release.sh
#   VERSION=1.2.3 zsh scripts/prepare-release.sh    override the version (default: ./VERSION, else 0.1.0)
#   STOP_AFTER_APPCAST=1 zsh scripts/prepare-release.sh
#                                                   dry run: stop once the signed appcast is verified and
#                                                   copied to dist/ (no SHA256SUMS.txt, no publish command)
#
# Steps: check that the keychain key matches SUPublicEDKey in Resources/Info.plist, build the app
# and DMG, zip the app, generate and verify the signed appcast.xml, write SHA256SUMS.txt in dist/
# and print the gh command that publishes the release. The command is printed, never run.
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
INFO_PLIST="$ROOT/Resources/Info.plist"
RELEASE_NOTES="$ROOT/Resources/ReleaseNotes.html"
KEY_ACCOUNT="io.github.claude-desktop-profiles"
REPO_URL="https://github.com/serhii-chernenko/claude-desktop-profiles"
APP_NAME="Claude Profiles"
ASSET_PREFIX="Claude-Profiles"

die() { print -u2 "ERROR: $*"; exit 1; }

read_version() {
  local from_file=""
  [[ -r $ROOT/VERSION ]] && from_file=$(<"$ROOT/VERSION")
  from_file=${from_file//[[:space:]]/}
  print -r -- "${VERSION:-${from_file:-0.1.0}}"
}

[[ $(uname -s) == Darwin ]] || die "Prepare releases on macOS."

VERSION_STRING=$(read_version)
[[ $VERSION_STRING =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "The version must look like 1.2.3 (got \"$VERSION_STRING\")."
[[ -f $RELEASE_NOTES ]] || die "Missing $RELEASE_NOTES"
grep -qF "<h2>$APP_NAME $VERSION_STRING</h2>" "$RELEASE_NOTES" \
  || die "Resources/ReleaseNotes.html has no \"<h2>$APP_NAME $VERSION_STRING</h2>\" heading: update the release notes first."

DMG_NAME="$ASSET_PREFIX-$VERSION_STRING.dmg"
ZIP_NAME="$ASSET_PREFIX-$VERSION_STRING.zip"
TAG="v$VERSION_STRING"

SPARKLE_DIR=$("$ROOT/scripts/fetch-sparkle.sh")
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")
ACTUAL_KEY=$("$SPARKLE_DIR/bin/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null) || ACTUAL_KEY=""
if [[ -z $ACTUAL_KEY || $ACTUAL_KEY != "$EXPECTED_KEY" ]]; then
  die "The update signing key for keychain account \"$KEY_ACCOUNT\" is missing or does not match SUPublicEDKey in Resources/Info.plist. Nothing was built or signed."
fi

VERSION=$VERSION_STRING SKIP_APP_BUILD=0 zsh "$ROOT/scripts/build-dmg.sh"
[[ -d $DIST/$APP_NAME.app ]] || die "Missing $DIST/$APP_NAME.app"
[[ -f $DIST/$DMG_NAME ]] || die "Missing $DIST/$DMG_NAME"

rm -f "$DIST/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$DIST/$APP_NAME.app" "$DIST/$ZIP_NAME"

RELEASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-release.XXXXXX")
trap 'rm -rf "$RELEASE_DIR"' EXIT
cp "$DIST/$ZIP_NAME" "$RELEASE_DIR/$ZIP_NAME"
cp "$RELEASE_NOTES" "$RELEASE_DIR/${ZIP_NAME:r}.html"

"$SPARKLE_DIR/bin/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
  --link "$REPO_URL" --embed-release-notes "$RELEASE_DIR"
"$SPARKLE_DIR/bin/sign_update" --account "$KEY_ACCOUNT" --verify "$RELEASE_DIR/appcast.xml"
cp "$RELEASE_DIR/appcast.xml" "$DIST/appcast.xml"

if [[ ${STOP_AFTER_APPCAST:-0} == 1 ]]; then
  rm -f "$DIST/SHA256SUMS.txt"
  print "Dry run: signed appcast verified and copied to dist/appcast.xml (version $VERSION_STRING)."
  exit 0
fi

(cd "$DIST" && shasum -a 256 "$DMG_NAME" "$ZIP_NAME" appcast.xml > SHA256SUMS.txt)

print ""
print "Signed release $VERSION_STRING is ready in dist/. Review it, push the release commit, then publish with:"
print ""
print -r -- "cd ${(q)ROOT} && gh release create $TAG \\"
print -r -- "  dist/$DMG_NAME dist/$ZIP_NAME dist/appcast.xml dist/SHA256SUMS.txt \\"
print -r -- "  --title \"$APP_NAME $VERSION_STRING\" --notes-file Resources/ReleaseNotes.html"
