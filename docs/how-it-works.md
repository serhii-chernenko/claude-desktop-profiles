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

A profile file holds `PROFILE_NAME`, `PROFILE_COLOR`, `PROFILE_HUE`, `PROFILE_SAT`, `PROFILE_DESKTOP`, `PROFILE_CLI`, `PROFILE_APP`, `PROFILE_LAUNCHER`, `PROFILE_BUNDLE_ID`, `PROFILE_DATA_DIR`, `PROFILE_CONFIG_DIR` and `PROFILE_DIRS`.

- `PROFILE_DESKTOP=0` (`--no-desktop`) is a CLI-only profile: no app and no launcher. `list --plain` prints `-` for its `app` and `data_dir`, so a client must not offer recolor, rebuild or link for it.
- `PROFILE_CLI=0` (`--no-cli`) is a desktop-only profile: no `claude-<slug>` function and no folder rules.
- `PROFILE_COLOR` shows as `-` in `list --plain` when unset. `--hue DEG` is the **target** hue of the icon, not a rotation; the stored `PROFILE_HUE` is the computed shift from the source icon.
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

Builds use `SIGN_IDENTITY` when present. A missing identity falls back to ad-hoc signing with a warning. An identity that exists but fails a test signature is an error: silently falling back to ad-hoc would quietly reintroduce the prompts. `build`, `launcher` and `recolor` all use this rule.

### 7. Where the Code tab keeps its sessions

The desktop app's Code-tab index lives in `<data-dir>/claude-code-sessions/<account>/<org>/local_*.json`. It is bound to the account, so it is not migrated between profiles. The transcripts themselves are in the config dir and stay usable from the CLI.

### 8. Sandboxed agents cannot do `setup`

Auto-mode agents and sandboxed shells cannot import keychain identities, answer the trust prompt or run `launchctl bootstrap`. `setup` is therefore always run by a human in Terminal.

### 9. The icon

Modern Claude.app has both `CFBundleIconName` (an asset catalog, `Assets.car`) and `CFBundleIconFile` (`electron.icns`). The system prefers the catalog, which would show the original icon. The build deletes `CFBundleIconName` in the copy so the tinted `.icns` is used. The tint rotates the hue of every PNG in the iconset using CoreImage (`CIHueAdjust` plus `CIColorControls`), then `iconutil` rebuilds the `.icns`. The hue delta is computed relative to the **sampled** dominant hue of the source icon, not a constant, so a future Claude icon refresh does not break the colors.

### 10. Launching a copy takes over `claude://`

Electron registers the app as the default handler for its URL scheme on startup. Every launch of a profile copy therefore makes the copy the owner of `claude://`. Regular Claude then stops receiving deep links, and a link click launches the copy bare, on the main data folder (fact 5). Without a fix only `auto` (every 15 minutes) would notice.

The launcher fixes it after a fresh launch (not in the "already running" branch). It starts a detached shell step that sleeps 10 seconds, then restores the handler to the source app's bundle id with the bundled `urlhandler.js`, but only when all of these hold:

- the sign-in window for this profile is not open: `state/link-at` does not exist, names another slug, or is older than `LINK_TTL`;
- the handler currently is this profile's bundle id (a link window opened for a different profile is left alone).

`remove` restores the handler to regular Claude before it deletes the app when the handler points at the removed copy. `CLAUDE_PROFILES_NO_URL_SET` turns the CLI's handler changes into a warning; the launcher's step is not affected, so test the launcher by inspecting its script (`osadecompile`) and not by launching it.

## Build pipeline

1. Take a lock (`mkdir` of a lock dir; stale after 30 minutes) so the LaunchAgent and a manual build never overlap.
2. `ditto` the source app into a staging folder on the same volume as the destination.
3. Edit `Info.plist`: `CFBundleIdentifier`, `CFBundleDisplayName`, `LSEnvironment:CLAUDE_CONFIG_DIR`, delete `CFBundleIconName`.
4. Tint the icon.
5. Re-sign **inside-out**: every nested `.app`, `.framework`, `.xpc`, `.appex` and every Mach-O file, deepest paths first, then the main executable (with `--identifier <bundle-id>`), then the bundle. Each item keeps its own entitlements, minus the ones an ad-hoc or self-signed signature cannot carry (`com.apple.developer.*`, `com.apple.application-identifier`, `keychain-access-groups`, team identifiers), which would make macOS kill the process at launch. Entitlements such as the virtualization one stay.
6. Verify the signature, re-check that the copy is not running, then swap the staged bundle into place (the old copy is kept until the move succeeded).
7. Build the launcher with `osacompile`, copy `lib/urlhandler.js` into its `Contents/Resources`, give it the copy's icon and register both with `lsregister -f`; `killall Dock` when run interactively.

`recolor` is the fast path: it re-tints the `.icns` from the **source** app's icon (never from the already tinted one), re-signs only the outer bundle, rebuilds the launcher, refreshes Launch Services and restarts the Dock. It works while the copy is running; the Dock updates after the copy restarts.

## The auto-rebuild agent

`setup` writes one LaunchAgent (`io.github.claude-desktop-profiles.rebuild` by default) that runs `claude-profiles auto` on three triggers: a change of `/Applications/Claude.app` (`WatchPaths`), a 15-minute interval and load time. For every desktop profile, under one lock, `auto`:

1. fixes bare launches;
2. restores `claude://` to regular Claude once the link window expired (also the backstop for copies started without the launcher, see fact 10);
3. decides whether the copy is stale: missing, wrong bundle ID (the copy's own updater can overwrite it), version differs from the source, launcher missing, `LSEnvironment` missing, or not signed by the configured identity;
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
