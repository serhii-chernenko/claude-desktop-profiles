# Manual procedure (for Claude Code, or a human)

Use this when `bin/claude-profiles` cannot be used (it fails, or the repository is incomplete). Every step is a plain shell command. If the utility works, prefer `bin/claude-profiles ... --yes` instead; this document is its fallback and its specification.

The tool builds profiles in **self mode** by default: one app, `/Applications/Claude <Name>.app`, whose `app.asar` carries a boot file that selects the data folder ([how-it-works.md](how-it-works.md), fact 13). That patch rewrites a binary archive and its integrity hash, so **do not do it by hand: use the CLI** (`bin/claude-profiles build <slug> --yes`, or `migrate-layout <slug> --yes` for an existing launcher-mode profile). Steps 1 to 6 below build the older **launcher mode** (a hidden copy plus a launcher), which needs no patch and is what to fall back to when the CLI cannot run. Step 6a has the read-only check whether self mode is possible on the installed Claude, and how to verify a self-mode app.

All commands are zsh. Replace the placeholders in the variables block once, then run the steps in order in the same shell session.

## Who does what

**Claude (or the human) can run every command in this document except the ones below.**

**Only the human can do these. Stop, tell the user exactly what to do, and wait:**

1. **`claude-profiles setup`** (signing identity import, trust prompt, key partition list, `launchctl bootstrap`). It needs the login password and cannot run in a sandboxed or auto-mode agent. Never run it for the user and never run its individual `security` or `launchctl` steps by hand. Ask the user to open Terminal and run `<repo>/bin/claude-profiles setup`.
2. **The Keychain prompt** for "Claude Safe Storage" on the first launch of a new copy: the user must click **Always Allow**. Likewise macOS privacy prompts (microphone, screen recording, accessibility).
3. **Pinning the profile to the Dock**: drag `/Applications/Claude <Name>.app` onto the Dock, or right-click its icon, Options, Keep in Dock. In self mode that is the app itself; in launcher mode it is the launcher, and the copy in the hidden folder `/Applications/.claude-profiles` is never pinned. `migrate-layout` refreshes or repoints existing pins by itself; `dock <slug> fix --dry-run` previews it (`show --plain` prints a `dock` row, `copy_pinned` or `old_launcher_pinned` when it is needed).
4. **Signing in** to the new account inside the new copy.

**Ask the user before doing any of these:**

- quitting a running Claude copy (they can lose open conversations);
- moving or deleting session history, config dirs or data dirs;
- editing shell startup files such as `~/.zshrc`;
- changing the `claude://` URL handler.

**Never touch:** `/Applications/Claude.app` (the source; it is only read), the Keychain, LaunchAgents, and any profile you were not asked to change.

## Newer CLI commands (use these before the manual steps)

These all accept `--yes` and the read-only ones accept `--plain`. Run `bin/claude-profiles help` for the exact flags.

| Need | Command |
| --- | --- |
| Inspect state | `status --plain` (CLI install, signing identity, agent, source app, `claude://` handler), `show <slug> --plain`, `scan --plain` |
| Move session history into an **existing** profile | `projects <slug> list --plain`, then `projects <slug> add --mode symlink\|move\|copy [--no-dir] --yes CWD...` (ask first; `move` and `copy` change session history) |
| Register a hand-made copy | `scan --plain` prints `candidate` rows (app, launcher, bundle ID, data dir, config dir, name, signing identity or `-`); pass them to `adopt --slug s --name N --app PATH [--launcher PATH] [--data-dir P] [--config-dir P] [--identity NAME]` (the identity is detected from the copy when omitted) |
| Shell hook in `~/.zshrc` | `shell-init status --plain`, then `shell-init install` or `shell-init uninstall` (an idempotent marked block; ask first, because it edits a shell startup file) |
| Old hand-made LaunchAgents | `legacy-agents --plain` to list, `legacy-agents disable LABEL --yes` to unload and rename one (ask first) |
| Move a launcher-mode profile to self mode (one app) | `show <slug> --plain` prints `mode` `self` or `launcher` (and `layout` `self`, `hidden` or `legacy`). For `launcher`: quit the copy (ask first), `migrate-layout <slug> --yes`. It rebuilds the copy from Claude.app with the boot file, puts it at `/Applications/Claude <Name>.app` in place of the launcher, removes the hidden copy and refreshes the Dock pin. It exits 3 and prints `agent` rows when an old LaunchAgent would recreate the copy; ask the user, then `legacy-agents disable LABEL --yes` and retry. A plain `build` does the same move; `build <slug> --mode launcher` goes back |
| CLI on the PATH | `install-cli` copies the tool to `~/.local/share/claude-profiles` and links `~/.local/bin/claude-profiles` |

`setup` is never in this list: it is always run by the human in Terminal, because it needs their login password. The native app does the same: its **Set Up** button opens Terminal for the user and never handles the password.

## 0. Variables

```zsh
NAME="<Name>"
SLUG="<slug>"
SRC="/Applications/Claude.app"
APPS_DIR="/Applications/.claude-profiles"
APP="$APPS_DIR/Claude $NAME.app"
LAUNCHER="/Applications/Claude $NAME.app"
BUNDLE_ID="com.anthropic.claudefordesktop.$SLUG"
LAUNCHER_ID="$BUNDLE_ID.launcher"
DATA_DIR="$HOME/Library/Application Support/Claude-${NAME// /-}"
CONFIG_DIR="$HOME/.claude-$SLUG"
COLOR="#<rrggbb>"
IDENTITY="Claude Profiles Signing"
PB=/usr/libexec/PlistBuddy
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORK=$(mktemp -d)
echo "work dir: $WORK"
```

- `<Name>` is the display name, for example `Work`. `<slug>` is lowercase `[a-z0-9-]+`, for example `work`.
- `<rrggbb>` is the exact color the icon's body should get, for example `3a7bd5`.
- `APPS_DIR` is the `APPS_DIR` key of `~/.config/claude-profiles/config.env` when set. The copy goes there (Spotlight and Finder skip the dot-folder); the launcher goes to `/Applications` and is named exactly like the copy, so search shows one entry. `$LAUNCHER` must never equal `$APP`.
- To reuse an existing data or config folder, set `DATA_DIR` or `CONFIG_DIR` to it instead (candidates are listed in step 7).

## 1. Preflight

```zsh
[[ -d $SRC ]] && echo "source ok" || echo "MISSING: $SRC"
sw_vers -productVersion
[[ -e $APP ]] && echo "EXISTS: $APP (this is a rebuild)"
pgrep -fl "^$APP/Contents/MacOS/" || echo "copy not running"
pgrep -fl "^$SRC/Contents/MacOS/" || echo "source not running"
```

- The macOS version must be 13 or newer.
- If the copy is running, ask the user to quit it, or ask permission to quit it: `osascript -e "tell application id \"$BUNDLE_ID\" to quit"`.

Choose the signing identity. A named identity is used when it exists and works; otherwise ad-hoc (`-`):

```zsh
SIGN_ID=-
if security find-certificate -c "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  cp /usr/bin/true "$WORK/probe"
  if codesign --force --sign "$IDENTITY" --timestamp=none "$WORK/probe" </dev/null >/dev/null 2>&1; then
    SIGN_ID="$IDENTITY"
  else
    echo "STOP: identity exists but cannot sign (locked keychain?). Do not fall back to ad-hoc. Ask the user to unlock the login keychain or run setup."
  fi
fi
echo "SIGN_ID=$SIGN_ID"
```

If the output says STOP, stop and report it to the user.

## 2. Copy the app and edit its Info.plist

```zsh
STAGE="$WORK/stage/Claude $NAME.app"
mkdir -p "$WORK/stage"
ditto "$SRC" "$STAGE"
PLIST="$STAGE/Contents/Info.plist"

$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
$PB -c "Set :CFBundleDisplayName $NAME" "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleDisplayName string $NAME" "$PLIST"
$PB -c "Add :LSEnvironment dict" "$PLIST" 2>/dev/null || true
$PB -c "Delete :LSEnvironment:CLAUDE_CONFIG_DIR" "$PLIST" 2>/dev/null || true
$PB -c "Add :LSEnvironment:CLAUDE_CONFIG_DIR string $CONFIG_DIR" "$PLIST"
$PB -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true

EXE=$($PB -c "Print :CFBundleExecutable" "$PLIST")
echo "executable: $EXE"
```

`CFBundleExecutable` must stay the real binary: never replace it with a script (see [how-it-works.md](how-it-works.md), fact 1). Skip the two `LSEnvironment:CLAUDE_CONFIG_DIR` lines only for a profile whose config dir is `~/.claude`.

## 3. Tint the icon

Tint every PNG of the icon set with the `color.js tint` command from `lib/` of this repository (inside the app it is `Contents/Resources/cli/lib/color.js`). It fills the colored region of the source icon with exactly `$COLOR` and overlays a subtle dark-at-the-bottom gradient measured from the source icon, so the top of the tile matches `$COLOR` and the white glyph and edges stay intact:

```zsh
ICON_FILE=$($PB -c "Print :CFBundleIconFile" "$PLIST" 2>/dev/null || true)
if [[ -n $ICON_FILE ]]; then
  ICNS="$STAGE/Contents/Resources/${ICON_FILE%.icns}.icns"
else
  found=("$STAGE"/Contents/Resources/*.icns(N)); ICNS=${found[1]:-}
  [[ -n $ICNS ]] && $PB -c "Add :CFBundleIconFile string ${ICNS:t}" "$PLIST"
fi
iconutil -c iconset "$ICNS" -o "$WORK/icon.iconset"
largest=("$WORK"/icon.iconset/*.png(.OL[1]))
osascript -l JavaScript lib/color.js tint "$WORK/icon.iconset" "$COLOR" "$largest[1]"
iconutil -c icns "$WORK/icon.iconset" -o "$ICNS"
```

If the icon cannot be tinted, continue: the copy still works, it just looks like the original.

## 4. Re-sign inside-out

Each nested item is signed first, keeping its entitlements minus the ones that get the process killed under a non-Apple signature. Save and run this script:

```zsh
cat > "$WORK/sign.zsh" <<'SIGN'
#!/bin/zsh
STAGE=$1 EXE=$2 BUNDLE_ID=$3 SIGN_ID=$4
PB=/usr/libexec/PlistBuddy
ENT=$(mktemp)

sanitize_ents() {
  local key
  for key in ${(f)"$($PB -c Print "$1" 2>/dev/null | awk -F' = ' '/^    [^ }]/{sub(/^ +/,"",$1); print $1}')"}; do
    case $key in
      com.apple.developer.*|com.apple.application-identifier|keychain-access-groups|*team-identifier)
        $PB -c "Delete :$key" "$1" ;;
    esac
  done
  $PB -c Print "$1" 2>/dev/null | grep -q '^    [^ }]'
}

sign_one() {
  local path=$1 id_args=() ts_args=()
  [[ -n ${2:-} ]] && id_args=(--identifier "$2")
  [[ $SIGN_ID != - ]] && ts_args=(--timestamp=none)
  rm -f "$ENT"
  if codesign -d --entitlements - --xml "$path" > "$ENT" 2>/dev/null && [[ -s $ENT ]] && sanitize_ents "$ENT"; then
    codesign --force --sign "$SIGN_ID" "${ts_args[@]}" "${id_args[@]}" --entitlements "$ENT" "$path" 2>/dev/null
  else
    codesign --force --sign "$SIGN_ID" "${ts_args[@]}" "${id_args[@]}" "$path" 2>/dev/null
  fi
}

xattr -cr "$STAGE"
{
  find "$STAGE/Contents" -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0
  find "$STAGE/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.node' -o -name '*.so' \) -print0 \
    | while IFS= read -r -d '' f; do { file -b "$f" | grep -q Mach-O && printf '%s\0' "$f"; } || true; done
} | while IFS= read -r -d '' f; do
      printf '%d\t%s\n' "$(tr -cd / <<<"$f" | wc -c)" "$f"
    done | sort -rn | cut -f2- | while IFS= read -r f; do
      [[ $f == "$STAGE/Contents/MacOS/$EXE" ]] && continue
      sign_one "$f" || echo "WARN: could not sign ${f#$STAGE/}"
    done

sign_one "$STAGE/Contents/MacOS/$EXE" "$BUNDLE_ID"
bundle_ts=(); [[ $SIGN_ID != - ]] && bundle_ts=(--timestamp=none)
codesign --force --sign "$SIGN_ID" "${bundle_ts[@]}" "$STAGE"
codesign --verify --deep --strict "$STAGE" && echo "signature verified"
rm -f "$ENT"
SIGN

zsh "$WORK/sign.zsh" "$STAGE" "$EXE" "$BUNDLE_ID" "$SIGN_ID"
```

This takes about a minute. A few `WARN: could not sign` lines are usually harmless; do not continue until `signature verified` appears.

## 5. Swap the copy into place

Confirm again that the copy is not running, then:

```zsh
mkdir -p "$APPS_DIR"
if pgrep -f "^$APP/Contents/MacOS/" >/dev/null; then
  echo "STOP: copy is running"
else
  rm -rf "$APP.old"
  [[ -e $APP ]] && mv "$APP" "$APP.old"
  if mv "$STAGE" "$APP"; then
    rm -rf "$APP.old"
  else
    [[ -e $APP.old ]] && mv "$APP.old" "$APP"
    echo "STOP: move failed, previous copy restored"
  fi
fi
touch "$APP"
"$LSREG" -f "$APP"
ICNS="$APP/Contents/Resources/${ICNS:t}"
```

Writing to `/Applications` normally works for an admin user. If it is denied, ask the user.

## 6. Build the launcher

The launcher starts the copy with its own data and config dirs, then gives the `claude://` scheme back to regular Claude (see [how-it-works.md](how-it-works.md), fact 10). It is a small AppleScript applet plus two files in its `Contents/Resources`: `urlhandler.js` (copied from this repository's `lib/`) and `restore-link.sh`.

```zsh
cat > "$WORK/launcher.applescript" <<EOF
if application id "$BUNDLE_ID" is running then
  tell application id "$BUNDLE_ID"
    reopen
    activate
  end tell
else
  do shell script "open -n -b $BUNDLE_ID --env " & quoted form of "CLAUDE_CONFIG_DIR=$CONFIG_DIR" & " --args " & quoted form of "--user-data-dir=$DATA_DIR"
  do shell script "/bin/sh " & quoted form of (POSIX path of (path to resource "restore-link.sh")) & " >/dev/null 2>&1 &"
end if
EOF

[[ $LAUNCHER != "$APP" ]] || echo "STOP: the launcher path equals the copy; fix the variables before going on"
[[ $LAUNCHER != "$APP" ]] && rm -rf "$LAUNCHER"
osacompile -o "$LAUNCHER" "$WORK/launcher.applescript"
REPO="<path-of-this-repository>"
cp "$REPO/lib/urlhandler.js" "$LAUNCHER/Contents/Resources/urlhandler.js"
STAMP="$HOME/.config/claude-profiles/state/link-at"
SRC_ID=$($PB -c "Print :CFBundleIdentifier" "$SRC/Contents/Info.plist")
cat > "$LAUNCHER/Contents/Resources/restore-link.sh" <<EOF
stamp="$STAMP"; slug="$SLUG"; ttl=900; bid="$BUNDLE_ID"; src="$SRC_ID"; scheme=claude
EOF
cat >> "$LAUNCHER/Contents/Resources/restore-link.sh" <<'RESTORE'
js="$(dirname "$0")/urlhandler.js"
sleep 10
if [ -r "$stamp" ]; then
  read -r s_slug s_at < "$stamp"
  case "$s_at" in ""|*[!0-9]*) s_at=0;; esac
  if [ "$s_slug" = "$slug" ] && [ $(( $(date +%s) - s_at )) -le "$ttl" ]; then exit 0; fi
fi
cur=$(/usr/bin/osascript -l JavaScript "$js" get "$scheme" | tr '[:upper:]' '[:lower:]')
[ "$cur" = "$(printf %s "$bid" | tr '[:upper:]' '[:lower:]')" ] || exit 0
/usr/bin/osascript -l JavaScript "$js" set "$scheme" "$src"
RESTORE
LPLIST="$LAUNCHER/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier $LAUNCHER_ID" "$LPLIST" 2>/dev/null || $PB -c "Add :CFBundleIdentifier string $LAUNCHER_ID" "$LPLIST"
$PB -c "Delete :CFBundleIconName" "$LPLIST" 2>/dev/null || true
rm -f "$LAUNCHER/Contents/Resources/Assets.car"
cp "$ICNS" "$LAUNCHER/Contents/Resources/applet.icns"
xattr -cr "$LAUNCHER"
TS=(); [[ $SIGN_ID != - ]] && TS=(--timestamp=none)
codesign --force --sign "$SIGN_ID" "${TS[@]}" "$LAUNCHER"
touch "$LAUNCHER"
"$LSREG" -f "$LAUNCHER"
```

Refresh the Dock icons (this briefly restarts the Dock):

```zsh
killall Dock
```

The restore step runs 10 seconds after a fresh launch and does nothing while a `link <slug>` window for this profile is open (`state/link-at` names the slug and is younger than `LINK_TTL`, 900 seconds by default) or when the handler is not this copy any more. Without it, launching the copy makes it the `claude://` handler and regular Claude stops receiving links.

The launcher is the thing to start and to pin. Opening `$APP` directly runs it on the main data folder. `osacompile` resolves `application id "$BUNDLE_ID"`, so the copy must be registered with `lsregister -f` (step 5) before this step. The launcher's `open -b` finds the copy through that registration, not through its path.

## 6a. Self mode: use the CLI, then verify

Check first, read-only, whether the installed Claude can be patched (this is what the CLI checks before every self-mode build; if either hash differs, stay in launcher mode):

```zsh
ASAR="$SRC/Contents/Resources/app.asar"
u32() { od -An -t u4 -j "$2" -N 4 -- "$1" | tr -d " \n"; }
LEN=$(u32 "$ASAR" 12); BASE=$(( 8 + $(u32 "$ASAR" 4) ))
head -c $(( 16 + LEN )) "$ASAR" | tail -c "$LEN" > "$WORK/header.json"
echo "header $(shasum -a 256 "$WORK/header.json" | cut -d" " -f1)"
echo "plist  $($PB -c "Print :ElectronAsarIntegrity:Resources/app.asar:hash" "$SRC/Contents/Info.plist")"
read -r OFF SIZE HASH BLOCKS BLOCK_SIZE <<<"$(osascript -l JavaScript -e "function run(a){const h=JSON.parse(\$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null).js);const e=h.files[\"package.json\"];return [e.offset,e.size,e.integrity.hash,e.integrity.blocks.join(\",\"),e.integrity.blockSize].join(\" \")}" "$WORK/header.json")"
echo "package.json $(dd if="$ASAR" bs=1 skip=$(( BASE + OFF )) count="$SIZE" 2>/dev/null | shasum -a 256 | cut -d" " -f1) entry $HASH blocks $BLOCKS block size $BLOCK_SIZE"
```

The two header lines must match, the three package.json hashes must be equal, and the block size must be 4194304. Then build with the CLI (the patch, the integrity hash, the inside-out signature and the Dock fix are all done there):

```zsh
bin/claude-profiles new --name "$NAME" --slug "$SLUG" --color "$COLOR" --data-dir "$DATA_DIR" --config-dir "$CONFIG_DIR" --yes
```

For an existing profile use `bin/claude-profiles migrate-layout "$SLUG" --yes` (quit the copy first). If `build` prints `WARN: Self mode is not possible`, it built launcher mode instead; that is a safe result.

Verify a self-mode app (`bin/claude-profiles check "$SLUG"` runs the same checks):

```zsh
APP="/Applications/Claude $NAME.app"
A="$APP/Contents/Resources/app.asar"
L=$(u32 "$A" 12); head -c $(( 16 + L )) "$A" | tail -c "$L" > "$WORK/self-header.json"
[[ $(shasum -a 256 "$WORK/self-header.json" | cut -d" " -f1) == $($PB -c "Print :ElectronAsarIntegrity:Resources/app.asar:hash" "$APP/Contents/Info.plist") ]] && echo "OK plist hash matches the header" || echo "FAIL hash mismatch: the app will not start"
grep -q "\"cdp-boot.js\"" "$WORK/self-header.json" && echo "OK boot entry present" || echo "FAIL no boot entry"
[[ ! -e $LAUNCHER || $($PB -c "Print :CFBundleIdentifier" "$LAUNCHER/Contents/Info.plist") == "$BUNDLE_ID" ]] && echo "OK no separate launcher"
```

After the user opened the app once (any way: Dock, Spotlight, `open -b "$BUNDLE_ID"`):

```zsh
PIDS=$(pgrep -f "^$APP/Contents/" | paste -sd, -)
echo "open files in the profile data dir: $(lsof -p "$PIDS" 2>/dev/null | grep -cF "$DATA_DIR/")"
echo "open files in the main data dir (Crashpad included): $(lsof -p "$PIDS" 2>/dev/null | grep -cF "$HOME/Library/Application Support/Claude/")"
echo "open files in ~/.claude: $(lsof -p "$PIDS" 2>/dev/null | grep -cF "$HOME/.claude/")"
echo "open files in the main logs: $(lsof -p "$PIDS" 2>/dev/null | grep -cF "$HOME/Library/Logs/Claude/")"
PID=$(pgrep -f "^$APP/Contents/MacOS/" | head -1)
ps -E -ww -o command= -p "$PID" | tr " " "\n" | grep -qxF "CLAUDE_CONFIG_DIR=$CONFIG_DIR" && echo "OK CLAUDE_CONFIG_DIR set"
lsappinfo info -only pid -app "$BUNDLE_ID"
osascript -l JavaScript lib/urlhandler.js get claude
```

The first count must be above zero and the next three `0`; `lsappinfo` must print the same PID; the handler must still be the source app's bundle ID. A self-mode app has no `--user-data-dir` in its own command line (its helpers do); that is expected.

## 7. CLI profile (config dir)

A CLI profile is only a config directory. Its login is stored separately in the Keychain by Claude Code itself. A CLI-only profile (`--no-desktop`) needs only this step.

```zsh
mkdir -p "$CONFIG_DIR"
CLAUDE_CONFIG_DIR="$CONFIG_DIR" claude
```

Use it by prefixing commands with `CLAUDE_CONFIG_DIR="$CONFIG_DIR"`, or define an alias (ask the user before editing their shell startup file):

```zsh
alias claude-<slug>='CLAUDE_CONFIG_DIR=~/.claude-<slug> claude'
```

To find existing folders that could be adopted instead of creating new ones:

```zsh
ls -d ~/.claude ~/.claude-* 2>/dev/null
ls -d "$HOME/Library/Application Support/Claude" "$HOME/Library/Application Support"/Claude-* 2>/dev/null
```

To list the projects with history in a config dir together with their real working directory (the folder name cannot be reverse-decoded; the transcript's `cwd` field is the source of truth):

```zsh
FROM_CONFIG="$HOME/.claude"
for dir in "$FROM_CONFIG"/projects/*/; do
  first=$(ls "$dir"*.jsonl 2>/dev/null | head -1)
  [[ -n $first ]] || continue
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$first" | head -1 | sed 's/^"cwd":"//; s/"$//')
  printf '%s\t%s\t%s sessions\n' "${dir:t}" "$cwd" "$(ls "$dir"*.jsonl | wc -l | tr -d ' ')"
done
```

### Linking a project's history to the profile (ask the user first)

Options: share the history (symlink), reassign it (move) or copy it. `ENCODED` is the folder name printed above and `PROJECT_CWD` is its working directory. Quit Claude and any running Claude Code sessions before moving.

```zsh
ENCODED="<encoded-folder-name>"
PROJECT_CWD="<absolute-project-path>"
mkdir -p "$CONFIG_DIR/projects"
```

Pick exactly one:

```zsh
ln -s "$FROM_CONFIG/projects/$ENCODED" "$CONFIG_DIR/projects/$ENCODED"
```

```zsh
mv "$FROM_CONFIG/projects/$ENCODED" "$CONFIG_DIR/projects/$ENCODED"
```

```zsh
ditto "$FROM_CONFIG/projects/$ENCODED" "$CONFIG_DIR/projects/$ENCODED"
```

Then copy the project's entry in `.claude.json` (trust decisions, allowed tools). The file is `<config dir>/.claude.json`, except for `~/.claude`, where it is `~/.claude.json`:

```zsh
cat > "$WORK/copy-project.js" <<'JXA'
ObjC.import('Foundation');
function env(key) { const v = $.NSProcessInfo.processInfo.environment.objectForKey(key); return v.isNil() ? '' : ObjC.unwrap(v); }
function read(path) { return JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, $()))); }
const from = env('FROM_FILE'), to = env('TO_FILE'), cwd = env('PROJECT_CWD');
const source = read(from);
const target = $.NSFileManager.defaultManager.fileExistsAtPath(to) ? read(to) : {};
if (!source.projects || !source.projects[cwd]) throw new Error('no entry for ' + cwd + ' in ' + from);
target.projects = target.projects || {};
target.projects[cwd] = source.projects[cwd];
$(JSON.stringify(target, null, 2)).writeToFileAtomicallyEncodingError(to, true, $.NSUTF8StringEncoding, $());
JXA

cp "$CONFIG_DIR/.claude.json" "$CONFIG_DIR/.claude.json.bak" 2>/dev/null || true
FROM_FILE="$HOME/.claude.json" TO_FILE="$CONFIG_DIR/.claude.json" PROJECT_CWD="$PROJECT_CWD" osascript -l JavaScript "$WORK/copy-project.js"
```

Use `$FROM_CONFIG/.claude.json` as `FROM_FILE` when the source is not `~/.claude`. After a move, leave the old entry in place unless the user asks for it to be removed.

## 8. Verify

```zsh
codesign --verify --deep --strict "$APP" && echo "OK signature valid"
$PB -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"
$PB -c "Print :LSEnvironment:CLAUDE_CONFIG_DIR" "$APP/Contents/Info.plist"
$PB -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|Signature|Identifier"
[[ -d $LAUNCHER ]] && echo "OK launcher present"
[[ $LAUNCHER != "$APP" ]] && echo "OK launcher is not the copy"
mdfind "kMDItemCFBundleIdentifier == \"$BUNDLE_ID\"" | grep -qF "$APP" && echo "WARN the copy is indexed by Spotlight" || echo "OK the copy is hidden from Spotlight"
```

`Signature=adhoc` means no stable identity: acceptable, but the user will see Keychain prompts after every rebuild until they run `setup`.

After the user has launched the copy through the launcher once:

```zsh
[[ -n $(ls -A "$DATA_DIR" 2>/dev/null) ]] && echo "OK data dir populated" || echo "FAIL data dir empty: the copy ignored --user-data-dir"
PID=$(pgrep -f "^$APP/Contents/MacOS/" | head -1)
ps -ww -o command= -p "$PID" | grep -qF -- "--user-data-dir=$DATA_DIR" && echo "OK runs with --user-data-dir" || echo "FAIL bare launch: quit it and use the launcher"
ps -E -ww -o command= -p "$PID" | tr ' ' '\n' | grep -qxF "CLAUDE_CONFIG_DIR=$CONFIG_DIR" && echo "OK CLAUDE_CONFIG_DIR set" || echo "FAIL no CLAUDE_CONFIG_DIR"
echo "open files in ~/.claude: $(lsof -p "$PID" 2>/dev/null | grep -cF "$HOME/.claude/")"
echo "open files in the main data dir: $(lsof -p "$PID" 2>/dev/null | grep -cF "$HOME/Library/Application Support/Claude/")"
osascript -e "tell application \"System Events\" to tell (first process whose bundle identifier is \"$BUNDLE_ID\") to get {name, unix id, count of windows}"
launchctl print "gui/$(id -u)/io.github.claude-desktop-profiles.rebuild" >/dev/null 2>&1 && echo "OK LaunchAgent loaded" || echo "INFO LaunchAgent not installed (the user can run setup)"
```

A `FAIL` line means the copy was started without the launcher: quit it and open the launcher. Both `open files` counts should be `0`. The System Events line should show a non-zero PID; a PID of 0 means the executable was wrapped (step 2 was violated).

## 8b. Move an old layout to the hidden launcher layout

`claude-profiles migrate-layout` moves launcher-mode profiles to self mode (step 6a). The by-hand move below only applies when you stay in launcher mode.

Older versions kept the copy at `/Applications/Claude <Name>.app` next to `/Applications/Claude <Name> Launcher.app`, so search showed two entries. `claude-profiles migrate-layout <slug>` does this move; by hand, with the copy quit and no old LaunchAgent (`legacy-agents`) referencing it:

```zsh
OLD_APP="/Applications/Claude $NAME.app"
OLD_LAUNCHER="/Applications/Claude $NAME Launcher.app"
codesign --verify --deep --strict "$OLD_APP" && echo "signature ok before"
mkdir -p "$APPS_DIR"
mv "$OLD_APP" "$APP" || { ditto "$OLD_APP" "$APP" && rm -rf "$OLD_APP"; }
codesign --verify --deep --strict "$APP" && echo "signature ok after"
"$LSREG" -f "$APP"
"$LSREG" -u "$OLD_APP"
"$LSREG" -u "$OLD_LAUNCHER"; rm -rf "$OLD_LAUNCHER"
```

Then repeat step 6 (the launcher is built at `/Applications/Claude $NAME.app`, the path the copy just left), update `PROFILE_APP` and `PROFILE_LAUNCHER` in `~/.config/claude-profiles/profiles/<slug>.env`, and restart the Dock. Do not rebuild or re-sign the copy: moving keeps its signature and designated requirement, so Keychain and privacy permissions are unaffected. Remove Dock pins of the copy and repoint pins of the old launcher (`claude-profiles dock <slug> fix --yes`).

## 9. After Claude updates

Rebuild by repeating steps 1 to 6 with the same variables; the data and config dirs are untouched. The automatic version of this is the LaunchAgent that `setup` installs.

A self-mode app is rebuilt with `bin/claude-profiles build <slug> --yes` only (it repeats the patch). A copy is stale when its `CFBundleShortVersionString` or `CFBundleVersion` differs from the source's, its `CFBundleIdentifier` is not `$BUNDLE_ID`, the launcher (launcher mode) or the boot entry (self mode) is missing, or `LSEnvironment:CLAUDE_CONFIG_DIR` is missing:

```zsh
for key in CFBundleShortVersionString CFBundleVersion; do
  echo "$key source=$($PB -c "Print :$key" "$SRC/Contents/Info.plist") copy=$($PB -c "Print :$key" "$APP/Contents/Info.plist")"
done
```

## 10. Recolor only

Repeat step 3 on a fresh icon set taken from the **source** app (`$SRC/Contents/Resources/electron.icns`, never from the already tinted copy) and write the result over the copy's `.icns` and, in launcher mode, the launcher's `applet.icns`. Then re-sign only the outer bundles and refresh (in self mode there is no `$LAUNCHER` line; `app.asar` is not touched):

```zsh
TS=(); [[ $SIGN_ID != - ]] && TS=(--timestamp=none)
codesign --force --sign "$SIGN_ID" "${TS[@]}" "$APP"
codesign --force --sign "$SIGN_ID" "${TS[@]}" "$LAUNCHER"
"$LSREG" -f "$APP" "$LAUNCHER"
killall Dock
```

The change shows in the Dock after the copy restarts.

## 11. `claude://` sign-in links

Signing in on the web returns to the desktop app through a `claude://` link, which macOS sends to the app registered for the scheme (normally the original Claude). To sign in inside a copy, the scheme must temporarily point to the copy. Prefer `bin/claude-profiles link <slug>` and `bin/claude-profiles link main` (the latter restores the original). Changing the handler by hand is the user's decision: ask first, and remind them to restore it to `com.anthropic.claudefordesktop` when the sign-in is done. A copy that opens on the wrong profile after a link click is the symptom of a forgotten restore. A self-mode app never takes the scheme over (its boot file turns that registration into a no-op). In launcher mode, launching a copy takes the scheme over (Electron registers itself on startup); the launcher built in step 6 undoes that after about 10 seconds, so a copy started some other way (Finder, Spotlight) leaves the scheme pointing at it until `claude-profiles link main` or the `auto` agent restores it.

## 12. Remove a profile

Ask first. Quit the copy, check that `claude://` does not point at it, then remove the app and, in launcher mode, the launcher; keep the data and config dirs unless the user explicitly asks to delete them. `claude-profiles remove` restores the handler itself before deleting. By hand: run `osascript -l JavaScript lib/urlhandler.js get claude` and, if it prints `$BUNDLE_ID`, ask the user and run `osascript -l JavaScript lib/urlhandler.js set claude <source-bundle-id>` (the source app's `CFBundleIdentifier`).

```zsh
osascript -e "tell application id \"$BUNDLE_ID\" to quit"
sleep 3
rm -rf "$APP" "$LAUNCHER"
killall Dock
```

Deleting `$DATA_DIR` signs the account out of that copy; deleting `$CONFIG_DIR` deletes its session history. Do either only on an explicit request.

## 13. Clean up and report

```zsh
rm -rf "$WORK"
```

Then tell the user what is done and list the human-only steps still pending: pin `Claude <Name>` (the app in self mode, the launcher in launcher mode), sign in, click **Always Allow** on the Keychain prompt, and run the one-time `setup` in Terminal if `status --plain` shows the agent or identity missing (without it profiles do not follow Claude updates and every rebuild re-prompts Keychain and permissions).
