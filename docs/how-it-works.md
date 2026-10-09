# How it works

This page explains the mechanics behind `claude-profiles`, including the approaches that were tried and do not work. Read it before changing the build logic.

## Overview

A **desktop profile** is a full copy of `/Applications/Claude.app` with a different bundle ID, a tinted icon and its own data folder. It runs in one of two modes:

- **Self mode** (the default): the copy is `/Applications/Claude <Name>.app` and a boot file inside its `app.asar` selects the data folder (fact 13). One app per profile, no launcher.
- **Launcher mode** (the fallback, and how older profiles were built): a tiny **launcher app** starts the copy with the right switches. The copy lives in the hidden `APPS_DIR` (default `/Applications/.claude-profiles`) and the launcher in `/Applications`, so search shows one entry per profile (fact 12). A **CLI profile** is a separate `CLAUDE_CONFIG_DIR`. Both halves are independent: a profile may have either or both.

```
~/.config/claude-profiles/
  config.env              global settings (sourced by zsh); SOURCE_TEAM_ID (default Q6L2SF6YDW, empty disables) is the Apple Team ID Claude.app must be signed by before it is copied; APPS_DIR (default /Applications/.claude-profiles) is where app copies are built
  profiles/<slug>.env     one file per profile
  rules.tsv               derived: prefix<TAB>slug<TAB>config_dir (read by the shell hook)
  state/                  lock dir, staging, notification markers
  state/link-at           "<slug> <epoch>", written by `link <slug>`: the open sign-in window
```

A profile file holds `PROFILE_NAME`, `PROFILE_COLOR`, `PROFILE_SIGN_IDENTITY`, `PROFILE_DESKTOP`, `PROFILE_CLI`, `PROFILE_MODE`, `PROFILE_APP`, `PROFILE_LAUNCHER`, `PROFILE_BUNDLE_ID`, `PROFILE_DATA_DIR`, `PROFILE_CONFIG_DIR` and `PROFILE_DIRS`.

- `PROFILE_MODE` is `self` or `launcher`, the mode the app is built in. A file without it (written by an older version) is `launcher`. In self mode `PROFILE_LAUNCHER` is empty and `show --plain` prints `launcher -`, `layout self`, `mode self`.
- `PROFILE_DESKTOP=0` (`--no-desktop`) is a CLI-only profile: no app and no launcher. `list --plain` prints `-` for its `app` and `data_dir`, so a client must not offer recolor, rebuild or link for it.
- `PROFILE_CLI=0` (`--no-cli`) is a desktop-only profile: no `claude-<slug>` function and no folder rules.
- `PROFILE_COLOR` shows as `-` in `list --plain` when unset. `--hue DEG` is the **target** hue of the icon, not a rotation; the tool turns it into the color with that hue and the source icon's own saturation and value, and stores that hex. `PROFILE_HUE` and `PROFILE_SAT` of older profile files are ignored.
- `PROFILE_SIGN_IDENTITY` is empty by default (resolved automatically, see fact 6). `adopt` fills it from the copy's current signature, `set <slug> sign-identity NAME` changes it.
- `scan --plain` leaves out project folders without a `.jsonl` transcript and config dirs that have no `projects/`, `.claude.json` or `settings.json` (the main one is always listed).

Environment variables: `CLAUDE_PROFILES_HOME` (settings folder), `CLAUDE_PROFILES_LOG` (log file), `CLAUDE_PROFILES_APPS_DIR` (overrides `APPS_DIR`), `CLAUDE_PROFILES_LAUNCHER_DIR` (folder of self-mode apps and launchers, default `/Applications`), `CLAUDE_PROFILES_APP_MODE` (`self` or `launcher`, the mode of `new` and `build` without `--mode`), `CLAUDE_PROFILES_KEEP_MODE` (set by `auto` for its rebuilds: keep the current mode), `CLAUDE_PROFILES_AGENTS_DIR` (folder scanned for old LaunchAgents), `CLAUDE_PROFILES_NO_URL_SET` (never change the `claude://` handler; for tests) and, in the shell hook, `CLAUDE_PROFILES_MODE` (`auto`, `warn` or `off`, overrides `CLI_RULE_MODE`). `lib/json.js` copies a `.claude.json` to `<file>.claude-profiles.bak` before it rewrites it.

## Facts that shape the design

### 1. `CFBundleExecutable` must stay the real Electron binary

The obvious way to inject arguments is to replace the executable with a shell wrapper that does `exec .../Claude "$@"`. Do not. With a wrapper, Launch Services registers the app with PID 0. Accessibility clients, including window managers such as StageFit, then cannot find the app's windows. The copy keeps the original executable and receives its settings from the launcher and from `Info.plist` instead.

### 2. `--user-data-dir` is the only way to split the desktop data

Claude's packaged build deletes `CLAUDE_USER_DATA_DIR` from its environment at startup, so neither `LSEnvironment` nor `open --env` can select a data folder. The Chromium switch `--user-data-dir=<dir>` works, and it must be passed as an argument. That is why launcher mode needs a launcher. Self mode sets the same folder from inside the app instead (fact 13).

### 3. `CLAUDE_CONFIG_DIR` is not stripped

Claude Code, both inside the desktop app and in the terminal, honors `CLAUDE_CONFIG_DIR` for transcripts (`<config>/projects/<encoded-cwd>/*.jsonl`), `.claude.json` and settings. The CLI login is stored in the Keychain as `Claude Code-credentials-<hash-of-config-dir>`, so logins isolate automatically per config dir. A profile whose config dir is `~/.claude` has no override.

### 4. The launcher

```
if the copy is running:  reopen + activate
else:                    open -n -b <bundle-id> --env CLAUDE_CONFIG_DIR=<cfg> --args --user-data-dir=<data>
                         then, detached: (sleep 10; give claude:// back to regular Claude, see fact 10)
```

The launcher bundle carries `lib/urlhandler.js` in `Contents/Resources`. The slug, the bundle ids, the scheme, the stamp path and `LINK_TTL` are baked into the applet when it is built, so changing `LINK_TTL` takes effect after the next `launcher` or `build`. `open --env` needs macOS 13 or newer. As a backstop, the copy's `Info.plist` also carries `LSEnvironment` with `CLAUDE_CONFIG_DIR`, which covers launches that bypass the launcher for the config dir (but not for the data dir, see the next point).

### 5. A bare launch uses the main data folder (launcher mode)

Opening the copy from Spotlight, Finder, a `claude://` link or session restore starts it without `--user-data-dir`. It then runs on the main data folder at the same time as the real Claude; there is no single-instance guard. `claude-profiles auto` detects a copy whose command line lacks `--user-data-dir=<data>`, quits it and reopens it through the launcher. A self-mode copy has no such argument and needs none, so `auto` skips it. If it does not quit within 20 seconds it leaves it alone and notifies you.

### 6. Why a stable signing identity

An ad-hoc signature has a designated requirement based on the code directory hash, so every rebuild is a "different app" to macOS. That re-triggers the Keychain prompt for "Claude Safe Storage" and the privacy (TCC) prompts. A self-signed identity that is trusted for code signing gives a designated requirement based on the certificate, which stays the same across rebuilds. `setup` creates it, trusts it with `security add-trusted-cert -p codeSign`, and fixes the key partition list so `codesign` can use the key without a prompt.

The identity is chosen per profile, in this order, and the first one that is in the login keychain and passes a non-interactive test signature wins:

1. `PROFILE_SIGN_IDENTITY`, when set (`set <slug> sign-identity NAME`, or `adopt --identity`).
2. The identity that currently signs the copy's nested code: the first `Authority=` of `codesign -dvv` on `Contents/Frameworks/*Helper*.app`, then on the main executable. Apple and Developer ID authorities are not candidates. This keeps a hand-made copy on the identity it was made with, even if the global one is different.
3. The global `SIGN_IDENTITY` from `config.env`.
4. Ad-hoc, with a warning.

If no identity is usable but one of the candidates is in the keychain and its test signature failed (locked keychain, key access), `build`, `recolor`, `launcher` and `resign` stop instead of falling back: silently going ad-hoc would quietly reintroduce the prompts. `auto` skips such a profile for the same reason.

Mixed signatures are the failure to avoid. `codesign` without `--deep` re-signs only the outer bundle and leaves nested helpers alone, so an outer ad-hoc signature over helpers signed by an identity changes the designated requirement of the app while the helpers keep the old one, and Keychain and TCC ask again. `recolor`, `launcher` and `resign` therefore refuse to sign the outer bundle ad-hoc while the nested code carries a non-Apple identity that is not usable; `build` re-signs everything, so it cannot mix. `check` reports an ad-hoc outer bundle over identity-signed nested code as FAIL, and `resign <slug>` repairs it: it re-signs only the outer bundle and the launcher with the resolved identity. `auto` treats a copy whose outer signature is not the resolved identity as stale.

### 7. Where the Code tab keeps its sessions

The desktop app's Code-tab index lives in `<data-dir>/claude-code-sessions/<account>/<org>/local_*.json`. It is bound to the account, so it is not migrated between profiles. The transcripts themselves are in the config dir and stay usable from the CLI.

### 8. Sandboxed agents cannot do `setup`

Auto-mode agents and sandboxed shells cannot import keychain identities, answer the trust prompt or run `launchctl bootstrap`. `setup` is therefore always run by a human in Terminal.

### 9. The icon

Modern Claude.app has both `CFBundleIconName` (an asset catalog, `Assets.car`) and `CFBundleIconFile` (`electron.icns`). The system prefers the catalog, which would show the original icon. The build deletes `CFBundleIconName` in the copy so the tinted `.icns` is used. `lib/color.js tint` repaints every PNG of the iconset with the chosen color and a soft shade, then `iconutil` rebuilds the `.icns`:

1. **Measure the shade.** The source icon (always the original, never an already tinted one) is scaled to 128 px. The colored square is found as the first and last row whose middle columns are almost all saturated pixels. The mean color of a band near its top and of one near its bottom (3% to 9% of its height from each edge, middle 40% of the width, so the glyph is never sampled) gives the shade `A = 1 - Ybottom / Ytop`, where `Y` is the sRGB luma. The original gradient is a saturation ramp at constant HSV value, so the luma is what measures the darkening. For the current icon `A` is about 0.074. It is clamped to 0..0.3 and measured at run time, so a future icon refresh does not break the colors.
2. **Flat color.** Each pixel is mapped to exactly the chosen color with the weight `w = smoothstep(0.06, 0.22, s)` of its saturation `s`, and blended with the original by `1 - w`, so the nearly white glyph and the anti-aliased edges keep their colors. Grey and black targets work: the glyph stays white. This is a 64x64x64 `CIColorCube`, built in JXA (float data passed to CoreImage as base64-decoded `NSData`). A second cube with the same loop turns `w` into a mask of the colored region.
3. **Shade.** A `CILinearGradient` from black at alpha `A` at the bottom of the colored square to clear at its top is composited over the flat image and applied only through the mask (`CIBlendWithMask`), so the glyph is not darkened. The top of the icon is therefore exactly the chosen color and the bottom is about 7% darker, like the original.
4. **Color space.** All of it runs in sRGB (`CILinearToSRGBToneCurve` before, `CISRGBToneCurveToLinear` after), because CoreImage works in linear light by default.

The whole iconset takes about a second. The top of the colored region is within about 1/255 per channel of the requested color (the shade is already about 0.4% at 6% of the way down). The mean color of the whole icon is about 4% darker than the requested color.

### 10. Launching a copy takes over `claude://` (launcher mode)

Electron registers the app as the default handler for its URL scheme on startup (Claude calls `app.setAsDefaultProtocolClient` for `claude` and, depending on features, `claude-nest`, `claude-nest-prod` or `claude-dev`). A self-mode copy turns these calls into no-ops (fact 13), so the rest of this fact applies to launcher mode. Every launch of a profile copy therefore makes the copy the owner of `claude://`. Regular Claude then stops receiving deep links, and a link click launches the copy bare, on the main data folder (fact 5). Without a fix only `auto` (every 15 minutes) would notice.

The launcher fixes it after a fresh launch (not in the "already running" branch). It starts a detached shell step that sleeps 10 seconds, then restores the handler to the source app's bundle id with the bundled `urlhandler.js`, but only when all of these hold:

- the sign-in window for this profile is not open: `state/link-at` does not exist, names another slug, or is older than `LINK_TTL`;
- the handler currently is this profile's bundle id (a link window opened for a different profile is left alone).

`remove` restores the handler to regular Claude before it deletes the app when the handler points at the removed copy. `CLAUDE_PROFILES_NO_URL_SET` turns the CLI's handler changes into a warning; the launcher's step is not affected, so test the launcher by inspecting its script (`osadecompile`) and not by launching it.

### 11. Quarantine and where the CLI runs from

Everything inside a downloaded app carries the `com.apple.quarantine` attribute, and Gatekeeper may run a quarantined app from a read-only, randomized "translocated" path (`/private/var/folders/.../AppTranslocation/...`). A LaunchAgent that pointed inside the app would break when that path changes or the app moves, so `setup` refuses to install it from a disk image or a translocated app, and from any path that is not owned by you or is writable by group or others.

`install-cli` is the way out. It copies `bin/`, `lib/` and `VERSION` out of the app with `ditto --noqtn` (no quarantine flag) into `~/.local/share/claude-profiles`, applies `chmod -R go-w`, swaps the new copy into place and links `~/.local/bin/claude-profiles` to it. The copy is a stable, user-owned location that has never been quarantined, which is exactly what the LaunchAgent and the Terminal need. The app starts the CLI as `/bin/zsh -f <script>`, so it never depends on the script's executable bit or on the quarantine state. Everyday commands run from the copy inside the app; the **Set Up** button first runs `install-cli` and then opens Terminal on the installed copy. After installing a new version of the app, the app refreshes the installed copy itself on its next launch (when the command-line tool was installed and the bundled version is not older); **Update** in Settings (or `install-cli`) is the manual fallback.

### 12. Two apps, one search entry (launcher mode)

Spotlight and Raycast list every app they index, so a copy next to its launcher showed two nearly identical entries, and the wrong one (the copy) starts on the main data folder (fact 5). The layout therefore splits them by folder:

- The copy is `$APPS_DIR/Claude <Name>.app`. `APPS_DIR` defaults to `/Applications/.claude-profiles`: Spotlight does not index dot-folders and Finder hides them. The copy keeps `CFBundleName` and `CFBundleDisplayName` `Claude <Name>`, so the Dock and ⌘-Tab show the same name as the launcher. It is always registered with `lsregister -f` at its real path.
- The launcher is `/Applications/Claude <Name>.app`, named exactly like the profile, with bundle ID `<copy bundle ID>.launcher`.
- The launcher's `open -n -b <bundle id>` and the `application id` lookups in its applet resolve the copy through Launch Services, not through its path. That is why `osacompile` of the launcher needs the copy registered first, and why a stale registration of an old path must be removed (`lsregister -u`): two registered apps with one bundle ID make `open -b` ambiguous.
- Even so, a running launcher-mode profile shows two Dock icons (the pinned launcher and the running copy), and every launch path that bypasses the launcher (a pin of the copy, `claude://` links, login restore) starts the copy bare (fact 5). Self mode (fact 13) removes both problems.

A profile is in the **old layout** (`show --plain` prints `layout legacy`) when its copy is not in `APPS_DIR`. The tool only migrates automatically when the launcher is also named `<copy> Launcher.app` next to the copy; other hand-made arrangements are migrated only by an explicit `migrate-layout`.

The steps below are the move from the old layout to the hidden layout. Today `migrate-layout` moves launcher-mode profiles to self mode instead (fact 13); these steps still run when a `build --mode launcher` finds the old layout, and when `migrate-layout` falls back because self mode is not possible:

1. refuses while the copy is running, and while a legacy LaunchAgent (the `legacy-agents` detection: its program or watch paths contain the copy's path or the source app's) is present. Such an agent would rebuild the copy at the old path, which is now the launcher's path. The command exits 3 and prints the agent rows with `--plain`; inside `build` the block is only a warning and the build proceeds in the old layout, so Claude updates keep being applied;
2. resolves the signing identity (`choose_sign_id`) so a failure aborts before anything moved;
3. `mkdir -p APPS_DIR`, then `mv` the copy into it (`ditto` and remove the original if `mv` fails). It is a rename on one volume: the inode, signature and designated requirement are unchanged, so Keychain and TCC grants survive;
4. `codesign --verify --deep --strict` at the new path. If it passed before the move and fails after, the copy is moved back and the command stops;
5. `lsregister -f` the new path, `lsregister -u` the old one;
6. removes the old launcher (only when its bundle ID is `<copy bundle ID>.launcher`; anything else is left alone with a warning);
7. updates `PROFILE_APP` and `PROFILE_LAUNCHER`, refreshes `rules.tsv`, builds the new launcher at `/Applications/Claude <Name>.app` with the profile's resolved identity (never ad-hoc over an identity), and, unless run by `auto`, runs the Dock fix described below (which also restarts the Dock).

The Dock keeps a bookmark for each pinned app, so a pin of the copy follows it into `APPS_DIR`, and a pin of the removed `… Launcher.app` goes dead. `check` warns about the old layout and fails if the launcher path is the copy itself (building a launcher there would delete the copy; `build_launcher` and `remove` refuse that case too). `remove` also deletes `APPS_DIR` when it is left empty.

### 13. Self mode: the boot file inside `app.asar`

Self mode makes the copy pick its own data folder, so a profile is one app at `/Applications/Claude <Name>.app`, every launch path is correct, and the Dock pin and the running app are one icon. It works within the two constraints above: `CFBundleExecutable` stays the real Electron binary (fact 1), and nothing depends on `CLAUDE_USER_DATA_DIR` (fact 2).

**What Claude.app is made of.** These facts were verified on Claude 2.31226.0 and are re-checked on the source app before every self-mode build (`asar_validate`, read-only):

- `app.asar` is a Chromium pickle: `uint32 4`, `uint32 header pickle size`, `uint32 header payload size`, `uint32 JSON length`, the header JSON (UTF-8), zero padding to a multiple of 4, then the file data. The data starts at `8 + header pickle size`; the `offset` of each entry is a decimal string relative to that start.
- `Info.plist` has `ElectronAsarIntegrity → Resources/app.asar → {algorithm SHA256, hash}`. `hash` is the SHA-256 of the header JSON string only, not of the whole archive.
- Each packed file has `integrity {algorithm SHA256, hash, blockSize 4194304, blocks}`: `hash` covers the whole file, `blocks` holds one SHA-256 per 4 MiB block. Electron checks the blocks when it reads the file.
- The Electron fuses (after the sentinel `dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX` in `Electron Framework`, wire version 1, 9 fuses) enable `EnableEmbeddedAsarIntegrityValidation` and `OnlyLoadAppFromAsar` and disable `RunAsNode`, `NODE_OPTIONS` and the inspect arguments. Only code inside an `app.asar` that matches the plist runs.
- `package.json` `main` (today `.vite/build/index.pre.js`) is read from the archive, never hardcoded. `app.asar.unpacked` exists and is left alone.

**The patch** (`patch_asar`, on the staged copy only; `/Applications/Claude.app` is never written):

1. Read the header and check `package.json` against its integrity entry.
2. Write a new `package.json` whose `main` is `cdp-boot.js` and which keeps the original as `cdpOriginalMain` (`lib/asar.js package`).
3. Write `cdp-boot.js` with the profile's absolute data and config paths, the original main and the URL scheme baked in, plus a boot version (`ASAR_BOOT_VERSION`, `lib/asar.js boot`).
4. Append both files after the existing data. No existing byte moves relative to the start of the data, so every old offset stays valid. Add `cdp-boot.js` and replace `package.json` in the header with offset (a string, like asar writes it), size and integrity (one block: both files are far below 4 MiB). `lib/asar.js add` edits the JSON.
5. Re-serialise the pickle with the new sizes and padding, and write header, padding, the old data (`dd` with the old data start as block size), the boot file and `package.json`. Hashes come from `shasum -a 256`.
6. Verify the new archive: the header parses, both new entries match their bytes and their integrity hashes, `main` is the boot file, and the original main still hashes to its own integrity entry at its shifted position.
7. Put the new header hash into `Info.plist`. The copy is then re-signed inside-out like every build.

**The boot file** is the app's main script and runs before any Claude code:

- `app.setPath('userData', DATA)`, `sessionData` (when the Electron version knows it), `logs` → `DATA/Logs`, `crashDumps` → `DATA/Crashpad` (the Crashpad database follows), and `app.commandLine.appendSwitch('user-data-dir', DATA)`, which Chromium passes on to the helper processes. Electron supports `setPath('userData')` before `ready`: the browser process reads its local state and profile only after the main script ran. Claude's own main script uses the same call for its internal `CLAUDE_USER_DATA_DIR`.
- `process.env.CLAUDE_CONFIG_DIR ??= CFG`, left out when the profile uses `~/.claude`. `LSEnvironment` still carries it too, which is what `ps -E` shows.
- `app.setAsDefaultProtocolClient` and `removeAsDefaultProtocolClient` are wrapped: for `claude` and `claude-*` they return `true` without touching Launch Services, so the copy never takes `claude://` from regular Claude. `isDefaultProtocolClient` is left alone, so the copy knows it is not the handler and keeps Google sign-in in its in-app web authentication sheet. The copy keeps `CFBundleURLTypes`, so `link <slug>` can still send links to it.
- The original main is loaded with `Module._load(path, null, true)`, the call Electron itself uses, so it becomes `require.main` and `process.mainModule`. Its `__dirname`, its relative requires and its compile cache (keyed on `.vite/build`) are unchanged; the boot file sits at the archive root.

Claude records `localPairingDisabledReason = "userData relocated"` whenever the data folder is not the default one. That applied to launcher mode with `--user-data-dir` as well.

**Why it is safe.** The integrity chain stays complete: Electron checks the header against the plist, which is updated, and every file, the two new ones included, against its block hashes. The original files are not changed, only moved together, and the original main is re-hashed after the patch. The copy is fully re-signed, so the signature seals the new plist and archive. A copy whose plist hash is left stale does not start: Electron aborts at launch with `FATAL ... Integrity check failed for asar archive entry '<header>'` (the negative test). Main Claude and its data are never touched.

**Fallback.** `build` builds in launcher mode, with a WARN, when the source fails `asar_validate`: the integrity dictionary is not exactly one SHA256 entry for `Resources/app.asar`, the header format or hash does not match, `package.json` has an unknown integrity format or a hash mismatch, `main` is not a packed file, the archive already has `cdp-boot.js`, or the fuse wire is not version 1 with 9 fuses. `migrate-layout` refuses in that case (a profile in the old layout is moved to the hidden launcher layout instead). The checks are the manual Step 0 in [for-claude.md](for-claude.md).

**Mode changes.** `build` targets self mode unless `--mode launcher` or `CLAUDE_PROFILES_APP_MODE=launcher` is given; `auto` keeps each profile's mode (`CLAUDE_PROFILES_KEEP_MODE=1`), except for the fallback. Going to self mode, the new app replaces the launcher at `/Applications/Claude <Name>.app` (both are this tool's bundles, checked by bundle ID), the hidden copy is unregistered and deleted, `APPS_DIR` is removed when empty, the old `… Launcher.app` of the old layout is removed, the profile is saved, and the Dock fix refreshes the pin: it still has the launcher's `bundle-identifier`, so it is replaced by a fresh tile for the same path. Going back to launcher mode moves the copy into `APPS_DIR` and builds the launcher at the old path. Both refuse while the copy runs and while a legacy LaunchAgent references it.

**Checks.** `check` in self mode verifies the boot entry (present, integrity hash, wired as `main`, current version, baked data and config dirs), that the plist hash equals the recomputed header hash, open files of every process of the copy (`lsof`: files in the profile data dir, none in the main data dir with its Crashpad folder, `~/.claude` or `~/Library/Logs/Claude`), `CLAUDE_CONFIG_DIR` in the environment, the Launch Services PID and the `claude://` handler. `stale_reason` treats a missing or older boot entry, a plist hash mismatch and baked dirs that differ from the profile as stale.

**Recovery.** The boot file is the profile's source of truth, so a lost profile `.env` is not fatal. `scan` finds self-mode copies in `/Applications` by reading the boot entry inside their `app.asar` (`asar_boot_state`) and reports the baked data and config dirs; `adopt --app PATH` then registers the copy again in self mode without rebuilding it.

**Installed copy.** The LaunchAgent runs the copy made by `install-cli`, so it can lag behind the checkout. `check` and `status` compare a SHA-256 over the sorted files of `bin/`, `lib/` and `VERSION` of the running tool with the installed one and warn on a difference (`cli_current` in `status --plain`).

**Keychain prompt.** A copy that is not yet allowed to read "Claude Safe Storage" (ad-hoc signed, or before the first **Always Allow**) waits at startup on the Keychain prompt. While it is open the app does not handle Quit or `SIGTERM`. This is the same in both modes.

### Dock pins

In self mode the profile's app itself belongs in the Dock. `dock <slug> fix` keeps that pin and repoints or drops pins of the hidden copy, of `… Launcher.app`, and a pin at the app's path whose `bundle-identifier` is still the launcher's (left over from launcher mode). `show --plain` reports `ok`, `not_pinned` or `old_launcher_pinned`. The rest of this section describes launcher mode.

A pinned app copy opens bare (on the main profile) when it is closed, so only the launcher belongs in the Dock. `dock <slug> fix` reads `persistent-apps` from `defaults export com.apple.dock -` into a temp plist and compares the decoded `tile-data:file-data:_CFURLString` of each entry with the profile's paths:

- a pin of the copy is removed (replaced by the launcher when the launcher is not pinned yet);
- a pin of the old `… Launcher.app` is repointed to the launcher, or removed when the launcher is already pinned;
- a launcher pin whose `bundle-identifier` is not the launcher's (it was created while that path held the copy) is replaced by a fresh tile, so a stale bookmark cannot lead back to the copy;
- with none of them pinned nothing changes unless `--pin` appends a launcher tile.

New tiles are minimal (`file-data` URL, `file-label`, `tile-type`); the Dock fills in the rest. Edits use `plutil` on the temp plist and are validated (`plutil -lint`, entry count) before the original export is saved as `dock-backup-<timestamp>.plist` (under `~/Library/Application Support/claude-profiles`, or `$CLAUDE_PROFILES_HOME/backups` when that variable is set). The result goes back with `defaults import com.apple.dock` and `killall Dock`. `show --plain` reports the state as a `dock` row (`ok`, `copy_pinned`, `launcher_missing`, `old_launcher_pinned`, or `-` without a desktop app) and `check` warns for the two fixable ones. `remove` drops every pin of the removed launcher and copy.

`CLAUDE_PROFILES_DOCK_PLIST=FILE` makes all of this read and write FILE instead of the real Dock and skips `killall Dock`; the tests use it.

## App architecture

The native app (`Sources/ClaudeProfiles`, SwiftUI, compiled by `scripts/build-app.sh` into a universal binary) is a thin shell over the CLI. It holds no profile logic of its own:

- `CLIRunner` runs `bin/claude-profiles` (from `Contents/Resources/cli/`, or the path in `CLAUDE_PROFILES_CLI`) as a subprocess with `--yes`, streams the output to the log panel and returns the exit status and output.
- `PlainParser` parses the `--plain` output of `list`, `scan`, `show`, `projects <slug> list`, `status`, `shell-init status` and `legacy-agents`. Unknown rows and extra columns are ignored, so a newer CLI keeps working. That output is the contract between the two halves.
- The views (`SidebarView`, `ProfileDetailView`, `MainClaudeView`, `SettingsView` and the sheets) call `AppModel`, which calls the runner. The profile page reads the `mode` row: in self mode it shows "One app per profile; no launcher" in place of the launcher path and opens the app itself. **Move to new layout** appears on a profile whose `show --plain` reports `mode launcher` (or `layout legacy` from an older CLI); it runs `migrate-layout <slug> --yes --plain`, and when the CLI exits 3 the `agent` rows on stdout (the `legacy-agents --plain` format) are shown with a button that opens Settings at the old LaunchAgents. Anything that needs the login password, such as `setup`, opens Terminal instead (fact 8); the app never sees the password.
- `ClaudeProfiles --self-test` runs the parser checks, then the CLI against a temporary `HOME` and `CLAUDE_PROFILES_HOME`: it creates a CLI-only profile, edits folders, recolors, copies a project, installs the CLI and removes the profile. It needs neither Claude.app nor a window. `scripts/build-app.sh` runs it on every build, so CI covers it on a runner without Claude.
- `scripts/build-app.sh` copies `bin/`, `lib/` and the version into `Contents/Resources/cli/` with `ditto --noqtn` and signs the bundle ad-hoc (or with `SIGNING_IDENTITY`). `scripts/build-dmg.sh` stages the app with `cp -RX` and `xattr -cr`, verifies the signature in the stage, adds the Applications link, "READ ME FIRST.txt" and the README, and writes `SHA256SUMS.txt`.

## Build pipeline

1. Take a lock (`mkdir` of a lock dir; stale after 30 minutes) so the LaunchAgent and a manual build never overlap.
2. Choose the mode: `--mode`, else `CLAUDE_PROFILES_APP_MODE`, else the current one under `auto`, else self. Self mode needs `asar_validate` to pass on the source app and no legacy LaunchAgent referencing the copy; otherwise the build warns and uses launcher mode. A launcher-mode build of a profile in the old layout runs the layout migration (fact 12) first.
3. `ditto` the source app into a staging folder on the same volume as the destination (`APPS_DIR` is created when missing).
4. Edit `Info.plist`: `CFBundleIdentifier`, `CFBundleDisplayName`, `LSEnvironment:CLAUDE_CONFIG_DIR`, delete `CFBundleIconName`.
5. Tint the icon.
6. In self mode, patch `app.asar` and the `ElectronAsarIntegrity` hash (fact 13).
7. Re-sign **inside-out**: every nested `.app`, `.framework`, `.xpc`, `.appex` and every Mach-O file, deepest paths first, then the main executable (with `--identifier <bundle-id>`), then the bundle. Each item keeps its own entitlements, minus the ones an ad-hoc or self-signed signature cannot carry (`com.apple.developer.*`, `com.apple.application-identifier`, `keychain-access-groups`, team identifiers), which would make macOS kill the process at launch. Entitlements such as the virtualization one stay.
8. Verify the signature, re-check that the copy is not running, then swap the staged bundle into place (the old copy is kept until the move succeeded) and save the profile. After a mode change, remove the bundle the new one replaces (the hidden copy, an old launcher, or the self-mode app when going back to launcher mode).
9. In launcher mode, build the launcher at `/Applications/Claude <Name>.app` with `osacompile`, copy `lib/urlhandler.js` into its `Contents/Resources`, give it the copy's icon and register both with `lsregister -f`. After a mode change run the Dock fix, otherwise restart the Dock, both only when run interactively.

`recolor` is the fast path: it re-tints the `.icns` from the **source** app's icon (never from the already tinted one), re-signs only the outer bundle with the profile's resolved identity (`app.asar` is not touched), rebuilds the launcher in launcher mode, refreshes Launch Services and restarts the Dock. It works while the copy is running; the Dock updates after the copy restarts.

## App updates (Sparkle)

The app updates itself with [Sparkle 2](https://sparkle-project.org/) (version and SHA-256 pinned in `scripts/fetch-sparkle.sh`, which downloads and verifies it once into `.build/`). The app has no Apple Developer ID, so trust comes from an Ed25519 key pair instead of a code signature.

- **Embedding.** `scripts/build-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` (plus its license into `Contents/Resources`), links the executable with `@executable_path/../Frameworks` as rpath, and signs inside-out: the `Downloader.xpc` and `Installer.xpc` services (keeping their entitlements), `Autoupdate`, `Updater.app`, the framework, then the app bundle with `--identifier`. `--deep` signing is not enough (see Dead ends).
- **Info.plist keys.** `SUFeedURL` is the `appcast.xml` asset of the latest GitHub release (`releases/latest/download/appcast.xml`); `SUPublicEDKey` is the public half of the update key; `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` make Sparkle reject an unsigned feed and verify the archive before it is unpacked; `SUEnableAutomaticChecks` with `SUScheduledCheckInterval` 86400 checks about once a day while the app is open; `SUAutomaticallyUpdate` is off by default (the user turns on automatic installs in Settings); `SUSendProfileInfo` is off, so nothing about the Mac is sent.
- **Version numbers.** `CFBundleShortVersionString` is `VERSION`. `CFBundleVersion`, which Sparkle compares, is `major*10000 + minor*100 + patch`, so it only increases; minor and patch must stay below 100.
- **The signed appcast.** `scripts/prepare-release.sh` runs on the maintainer Mac, never in CI: it checks that the keychain key (account `io.github.claude-desktop-profiles`) matches `SUPublicEDKey`, builds the DMG, zips the app, runs `generate_appcast` over the ZIP and `Resources/ReleaseNotes.html` (embedded as the release notes, no delta updates), verifies the result with `sign_update --verify` and writes `SHA256SUMS.txt`. The maintainer then publishes `appcast.xml`, the ZIP, the DMG and the sums as one GitHub release.
- **Keeping the installed CLI current.** The LaunchAgent and the shell hook run the copy in `~/.local/share/claude-profiles`, not the one inside the app, so an app update would leave them on the old CLI. On the next launch of the app, if the command-line tool was installed, the app reads `status --plain`; when the `cli_current` row is `0` and the bundled `VERSION` is the same or newer than the installed one, it runs `install-cli --from <bundled cli>` silently (no password is needed, unlike `setup`) and logs the decision, so an older app never downgrades the installed tool. The LaunchAgent therefore does not keep running a stale CLI after an update.

## The auto-rebuild agent

`setup` writes one LaunchAgent (`io.github.claude-desktop-profiles.rebuild` by default) that runs `claude-profiles auto` on three triggers: a change of `/Applications/Claude.app` (`WatchPaths`), a 15-minute interval and load time. For every desktop profile, under one lock, `auto`:

1. fixes bare launches (launcher mode only);
2. restores `claude://` to regular Claude once the link window expired (also the backstop for copies started without the launcher, see fact 10);
3. decides whether the copy is stale: missing, wrong bundle ID (the copy's own updater can overwrite it), version differs from the source, launcher missing (launcher mode, at `PROFILE_LAUNCHER`, whichever layout), boot entry missing, outdated or not matching the profile or the plist hash (self mode), `LSEnvironment` missing, or not signed by the profile's resolved identity (including a mixed signature);
4. skips the source if its own signature is invalid (an update in progress);
5. if the copy is running, notifies once per version and waits; otherwise rebuilds it in its current mode (`CLAUDE_PROFILES_KEEP_MODE=1`), so the agent never moves a profile to self mode on its own.

## Dead ends

The history of the desktop layout, in order: a shell wrapper as the executable (broke window managers), `CLAUDE_USER_DATA_DIR` in the environment (stripped), a launcher next to the copy (two search entries), the copy hidden in `APPS_DIR` behind the launcher (one search entry, but two Dock icons and bare launches through every other path), and self mode (one app, fact 13).

- **Shell wrapper as executable**: PID 0 registration, window managers lose the app (fact 1).
- **`CLAUDE_USER_DATA_DIR` in `LSEnvironment` or `open --env`**: stripped by the app at startup (fact 2).
- **Only `CLAUDE_CONFIG_DIR` in `LSEnvironment`**: sets the CLI/Code config but leaves the desktop data folder shared.
- **Launcher plus hidden copy as the only design**: one search entry, but the Dock shows the pinned launcher and the running copy as two icons, and a pin of the copy, a `claude://` link or login restore starts the copy bare on the main data folder until `auto` repairs it (facts 5 and 12). It remains as the fallback.
- **Injecting the data folder with `NODE_OPTIONS=--require`, `ELECTRON_RUN_AS_NODE` or `--inspect`**: the fuses disable all three.
- **An unpacked `app` folder or a loose JavaScript file next to `app.asar`**: `OnlyLoadAppFromAsar` ignores it.
- **Editing `app.asar` without updating `ElectronAsarIntegrity`, or editing a file in place**: Electron aborts at startup or when it reads the file. Appending new entries and updating the header hash keeps the chain valid (fact 13).
- **Hardcoding `.vite/build/index.pre.js` as the original main**: it changes between Claude builds; it is read from `package.json` in the archive.
- **Ad-hoc signing for everything**: works, but re-prompts for Keychain and TCC after every rebuild (fact 6).
- **Signing the bundle only (`--deep`)**: nested helpers keep the original signature and the launch fails or loses entitlements; sign inside-out.
- **Keeping all entitlements**: restricted entitlements without a matching provisioning profile get the process killed at launch.
- **Leaving `CFBundleIconName`**: the tinted `.icns` is ignored (fact 9).
- **Reverse-decoding the project folder name** (`-Users-me-code-app`) to find the working directory: lossy, since both `/` and `-` become `-`. The tool reads the `"cwd"` field from the first line of a transcript instead.
- **Letting an automated agent run `setup`**: it cannot answer the password prompts (fact 8).
