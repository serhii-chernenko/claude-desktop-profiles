# How it works

This page explains the mechanics behind `claude-profiles`, including the approaches that were tried and do not work. Read it before changing the build logic.

## Overview

A **desktop profile** is a full copy of `/Applications/Claude.app` with a different bundle ID, a tinted icon and its own data folder. A tiny **launcher app** starts the copy with the right switches. A **CLI profile** is a separate `CLAUDE_CONFIG_DIR`. Both halves are independent: a profile may have either or both.

```
~/.config/claude-profiles/
  config.env              global settings (sourced by zsh); SOURCE_TEAM_ID (default Q6L2SF6YDW, empty disables) is the Apple Team ID Claude.app must be signed by before it is copied
  profiles/<slug>.env     one file per profile
  rules.tsv               derived: prefix<TAB>slug<TAB>config_dir (read by the shell hook)
  state/                  lock dir, staging, notification markers
  state/link-at           "<slug> <epoch>", written by `link <slug>`: the open sign-in window
```

A profile file holds `PROFILE_NAME`, `PROFILE_COLOR`, `PROFILE_SIGN_IDENTITY`, `PROFILE_DESKTOP`, `PROFILE_CLI`, `PROFILE_APP`, `PROFILE_LAUNCHER`, `PROFILE_BUNDLE_ID`, `PROFILE_DATA_DIR`, `PROFILE_CONFIG_DIR` and `PROFILE_DIRS`.

- `PROFILE_DESKTOP=0` (`--no-desktop`) is a CLI-only profile: no app and no launcher. `list --plain` prints `-` for its `app` and `data_dir`, so a client must not offer recolor, rebuild or link for it.
- `PROFILE_CLI=0` (`--no-cli`) is a desktop-only profile: no `claude-<slug>` function and no folder rules.
- `PROFILE_COLOR` shows as `-` in `list --plain` when unset. `--hue DEG` is the **target** hue of the icon, not a rotation; the tool turns it into the color with that hue and the source icon's own saturation and value, and stores that hex. `PROFILE_HUE` and `PROFILE_SAT` of older profile files are ignored.
- `PROFILE_SIGN_IDENTITY` is empty by default (resolved automatically, see fact 6). `adopt` fills it from the copy's current signature, `set <slug> sign-identity NAME` changes it.
- `scan --plain` leaves out project folders without a `.jsonl` transcript and config dirs that have no `projects/`, `.claude.json` or `settings.json` (the main one is always listed).

Environment variables: `CLAUDE_PROFILES_HOME` (settings folder), `CLAUDE_PROFILES_LOG` (log file), `CLAUDE_PROFILES_NO_URL_SET` (never change the `claude://` handler; for tests) and, in the shell hook, `CLAUDE_PROFILES_MODE` (`auto`, `warn` or `off`, overrides `CLI_RULE_MODE`). `lib/json.js` copies a `.claude.json` to `<file>.claude-profiles.bak` before it rewrites it.

## Facts that shape the design

### 1. `CFBundleExecutable` must stay the real Electron binary

The obvious way to inject arguments is to replace the executable with a shell wrapper that does `exec .../Claude "$@"`. Do not. With a wrapper, Launch Services registers the app with PID 0. Accessibility clients, including window managers such as StageFit, then cannot find the app's windows. The copy keeps the original executable and receives its settings from the launcher and from `Info.plist` instead.

### 2. `--user-data-dir` is the only way to split the desktop data

Claude's packaged build deletes `CLAUDE_USER_DATA_DIR` from its environment at startup, so neither `LSEnvironment` nor `open --env` can select a data folder. The Chromium switch `--user-data-dir=<dir>` works, and it must be passed as an argument. That is why a launcher exists at all.

### 3. `CLAUDE_CONFIG_DIR` is not stripped

Claude Code, both inside the desktop app and in the terminal, honors `CLAUDE_CONFIG_DIR` for transcripts (`<config>/projects/<encoded-cwd>/*.jsonl`), `.claude.json` and settings. The CLI login is stored in the Keychain as `Claude Code-credentials-<hash-of-config-dir>`, so logins isolate automatically per config dir. A profile whose config dir is `~/.claude` has no override.

### 4. The launcher

```
if the copy is running:  reopen + activate
else:                    open -n -b <bundle-id> --env CLAUDE_CONFIG_DIR=<cfg> --args --user-data-dir=<data>
                         then, detached: (sleep 10; give claude:// back to regular Claude, see fact 10)
```

The launcher bundle carries `lib/urlhandler.js` in `Contents/Resources`. The slug, the bundle ids, the scheme, the stamp path and `LINK_TTL` are baked into the applet when it is built, so changing `LINK_TTL` takes effect after the next `launcher` or `build`. `open --env` needs macOS 13 or newer. As a backstop, the copy's `Info.plist` also carries `LSEnvironment` with `CLAUDE_CONFIG_DIR`, which covers launches that bypass the launcher for the config dir (but not for the data dir, see the next point).

### 5. A bare launch uses the main data folder

Opening the copy from Spotlight, Finder, a `claude://` link or session restore starts it without `--user-data-dir`. It then runs on the main data folder at the same time as the real Claude; there is no single-instance guard. `claude-profiles auto` detects a copy whose command line lacks `--user-data-dir=<data>`, quits it and reopens it through the launcher. If it does not quit within 20 seconds it leaves it alone and notifies you.

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

Modern Claude.app has both `CFBundleIconName` (an asset catalog, `Assets.car`) and `CFBundleIconFile` (`electron.icns`). The system prefers the catalog, which would show the original icon. The build deletes `CFBundleIconName` in the copy so the tinted `.icns` is used. `lib/color.js tint` recolors every PNG of the iconset with an exact mapping, then `iconutil` rebuilds the `.icns`:

1. **Sample.** The source icon (always the original, never an already tinted one) is scaled to 128 px and its dominant color `(Hs, Ss, Vs)` is taken: pixels with saturation and value of at least 0.2 vote by `s*v` in a 36-bin hue histogram, and the winning bin's neighborhood is averaged. Nothing is hardcoded, so a future Claude icon refresh does not break the colors.
2. **Map in HSV.** The target `(Ht, St, Vt)` comes from the stored `PROFILE_COLOR`. Every pixel goes to `h' = h + (Ht - Hs)`, `s' = clamp(s * St / Ss)`, `v' = clamp(v * Vt / Vs)`, blended with the original by `w = smoothstep(0.06, 0.22, s)`, so the nearly white glyph and the anti-aliased edges keep their colors. Grey and black targets (`St` near 0) work: saturated pixels turn grey, the glyph stays white.
3. **Calibrate.** Clamping at `s = 1` and the blend make the plain ratios fall a little short, especially for very saturated targets. The scales are therefore refined for up to 12 rounds by running the real pipeline on a 33-step lookup table and measuring the dominant color of the result, until hue, saturation and value are within 0.003 of the target. The measurement pairs each result pixel with the source pixel that voted for the dominant color, so it also works for greys.
4. **Apply.** The final 64x64x64 `CIColorCube` table is built in JXA (float data passed to CoreImage as base64-decoded `NSData`) and applied to each PNG in sRGB: `CILinearToSRGBToneCurve`, `CIColorCube`, `CISRGBToneCurveToLinear`, because CoreImage works in linear light by default.

The whole iconset takes a few seconds. The dominant color of the result is within about 4/255 per channel of the requested color; an extremely saturated target such as `#f5b000` is the worst case because edge pixels blend with the white glyph.

### 10. Launching a copy takes over `claude://`

Electron registers the app as the default handler for its URL scheme on startup. Every launch of a profile copy therefore makes the copy the owner of `claude://`. Regular Claude then stops receiving deep links, and a link click launches the copy bare, on the main data folder (fact 5). Without a fix only `auto` (every 15 minutes) would notice.

The launcher fixes it after a fresh launch (not in the "already running" branch). It starts a detached shell step that sleeps 10 seconds, then restores the handler to the source app's bundle id with the bundled `urlhandler.js`, but only when all of these hold:

- the sign-in window for this profile is not open: `state/link-at` does not exist, names another slug, or is older than `LINK_TTL`;
- the handler currently is this profile's bundle id (a link window opened for a different profile is left alone).

`remove` restores the handler to regular Claude before it deletes the app when the handler points at the removed copy. `CLAUDE_PROFILES_NO_URL_SET` turns the CLI's handler changes into a warning; the launcher's step is not affected, so test the launcher by inspecting its script (`osadecompile`) and not by launching it.

### 11. Quarantine and where the CLI runs from

Everything inside a downloaded app carries the `com.apple.quarantine` attribute, and Gatekeeper may run a quarantined app from a read-only, randomized "translocated" path (`/private/var/folders/.../AppTranslocation/...`). A LaunchAgent that pointed inside the app would break when that path changes or the app moves, so `setup` refuses to install it from a disk image or a translocated app, and from any path that is not owned by you or is writable by group or others.

`install-cli` is the way out. It copies `bin/`, `lib/` and `VERSION` out of the app with `ditto --noqtn` (no quarantine flag) into `~/.local/share/claude-profiles`, applies `chmod -R go-w`, swaps the new copy into place and links `~/.local/bin/claude-profiles` to it. The copy is a stable, user-owned location that has never been quarantined, which is exactly what the LaunchAgent and the Terminal need. The app starts the CLI as `/bin/zsh -f <script>`, so it never depends on the script's executable bit or on the quarantine state. Everyday commands run from the copy inside the app; the **Set Up** button first runs `install-cli` and then opens Terminal on the installed copy. After installing a new version of the app, press **Update** in Settings (or run `install-cli`) so the installed copy matches.

## App architecture

The native app (`Sources/ClaudeProfiles`, SwiftUI, compiled by `scripts/build-app.sh` into a universal binary) is a thin shell over the CLI. It holds no profile logic of its own:

- `CLIRunner` runs `bin/claude-profiles` (from `Contents/Resources/cli/`, or the path in `CLAUDE_PROFILES_CLI`) as a subprocess with `--yes`, streams the output to the log panel and returns the exit status and output.
- `PlainParser` parses the `--plain` output of `list`, `scan`, `show`, `projects <slug> list`, `status`, `shell-init status` and `legacy-agents`. Unknown rows and extra columns are ignored, so a newer CLI keeps working. That output is the contract between the two halves.
- The views (`SidebarView`, `ProfileDetailView`, `MainClaudeView`, `SettingsView` and the sheets) call `AppModel`, which calls the runner. Anything that needs the login password, such as `setup`, opens Terminal instead (fact 8); the app never sees the password.
- `ClaudeProfiles --self-test` runs the parser checks, then the CLI against a temporary `HOME` and `CLAUDE_PROFILES_HOME`: it creates a CLI-only profile, edits folders, recolors, copies a project, installs the CLI and removes the profile. It needs neither Claude.app nor a window. `scripts/build-app.sh` runs it on every build, so CI covers it on a runner without Claude.
- `scripts/build-app.sh` copies `bin/`, `lib/` and the version into `Contents/Resources/cli/` with `ditto --noqtn` and signs the bundle ad-hoc (or with `SIGNING_IDENTITY`). `scripts/build-dmg.sh` stages the app with `cp -RX` and `xattr -cr`, verifies the signature in the stage, adds the Applications link, "READ ME FIRST.txt" and the README, and writes `SHA256SUMS.txt`.

## Build pipeline

1. Take a lock (`mkdir` of a lock dir; stale after 30 minutes) so the LaunchAgent and a manual build never overlap.
2. `ditto` the source app into a staging folder on the same volume as the destination.
3. Edit `Info.plist`: `CFBundleIdentifier`, `CFBundleDisplayName`, `LSEnvironment:CLAUDE_CONFIG_DIR`, delete `CFBundleIconName`.
4. Tint the icon.
5. Re-sign **inside-out**: every nested `.app`, `.framework`, `.xpc`, `.appex` and every Mach-O file, deepest paths first, then the main executable (with `--identifier <bundle-id>`), then the bundle. Each item keeps its own entitlements, minus the ones an ad-hoc or self-signed signature cannot carry (`com.apple.developer.*`, `com.apple.application-identifier`, `keychain-access-groups`, team identifiers), which would make macOS kill the process at launch. Entitlements such as the virtualization one stay.
6. Verify the signature, re-check that the copy is not running, then swap the staged bundle into place (the old copy is kept until the move succeeded).
7. Build the launcher with `osacompile`, copy `lib/urlhandler.js` into its `Contents/Resources`, give it the copy's icon and register both with `lsregister -f`; `killall Dock` when run interactively.

`recolor` is the fast path: it re-tints the `.icns` from the **source** app's icon (never from the already tinted one), re-signs only the outer bundle with the profile's resolved identity, rebuilds the launcher, refreshes Launch Services and restarts the Dock. It works while the copy is running; the Dock updates after the copy restarts.

## The auto-rebuild agent

`setup` writes one LaunchAgent (`io.github.claude-desktop-profiles.rebuild` by default) that runs `claude-profiles auto` on three triggers: a change of `/Applications/Claude.app` (`WatchPaths`), a 15-minute interval and load time. For every desktop profile, under one lock, `auto`:

1. fixes bare launches;
2. restores `claude://` to regular Claude once the link window expired (also the backstop for copies started without the launcher, see fact 10);
3. decides whether the copy is stale: missing, wrong bundle ID (the copy's own updater can overwrite it), version differs from the source, launcher missing, `LSEnvironment` missing, or not signed by the profile's resolved identity (including a mixed signature);
4. skips the source if its own signature is invalid (an update in progress);
5. if the copy is running, notifies once per version and waits; otherwise rebuilds.

## Dead ends

- **Shell wrapper as executable**: PID 0 registration, window managers lose the app (fact 1).
- **`CLAUDE_USER_DATA_DIR` in `LSEnvironment` or `open --env`**: stripped by the app at startup (fact 2).
- **Only `CLAUDE_CONFIG_DIR` in `LSEnvironment`**: sets the CLI/Code config but leaves the desktop data folder shared.
- **Ad-hoc signing for everything**: works, but re-prompts for Keychain and TCC after every rebuild (fact 6).
- **Signing the bundle only (`--deep`)**: nested helpers keep the original signature and the launch fails or loses entitlements; sign inside-out.
- **Keeping all entitlements**: restricted entitlements without a matching provisioning profile get the process killed at launch.
- **Leaving `CFBundleIconName`**: the tinted `.icns` is ignored (fact 9).
- **Reverse-decoding the project folder name** (`-Users-me-code-app`) to find the working directory: lossy, since both `/` and `-` become `-`. The tool reads the `"cwd"` field from the first line of a transcript instead.
- **Letting an automated agent run `setup`**: it cannot answer the password prompts (fact 8).
