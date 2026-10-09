# claude-desktop-profiles

Run several Claude accounts side by side on macOS, each with its own login, its own Dock icon and its own Claude Code history. Profile names are yours: nothing is hardcoded.

- **Claude desktop**: every profile is a copy of `/Applications/Claude.app` with its own bundle ID, its own data folder and a tinted icon. A small launcher app starts the copy on the right data folder.
- **Claude Code (CLI)**: every profile has its own `CLAUDE_CONFIG_DIR`. A shell hook picks the profile from the folder you are in.
- **Zero dependencies**: only tools that ship with macOS (zsh, `osascript`, PlistBuddy, `codesign`, `iconutil`, `ditto`, `security`, `launchctl`). No Homebrew packages, no Python, no Swift.

> Screenshot placeholder: the "Claude Profiles" menu and two tinted Claude icons in the Dock.

Requires macOS 13 or newer and an installed `/Applications/Claude.app`. The released app uses the standard applet icon; a local build (`zsh scripts/build-app.sh`) tints its icon from your Claude.app.

## Two ways to use it

### Path A: the app or the command line

1. Download `Claude-Profiles-<version>.dmg` from the [Releases](https://github.com/serhii-chernenko/claude-desktop-profiles/releases) page and drag **Claude Profiles** to Applications. Or clone this repository and run `zsh install.sh` to get only the CLI.
2. Open **Claude Profiles** and choose **Create profile** (or run `claude-profiles new`).
3. Pin the new **Claude `<Name>` Launcher** to the Dock. Always start the profile through its launcher.
4. Run **Set up auto-rebuild & stable signing** once (see [Updates and auto-rebuild](#updates-and-auto-rebuild)).

### Path B: ask Claude Code

1. Clone this repository and open Claude Code in it:

   ```sh
   git clone https://github.com/serhii-chernenko/claude-desktop-profiles.git
   cd claude-desktop-profiles
   claude
   ```

2. Say: "Create a profile called Work."
3. Claude Code follows [CLAUDE.md](CLAUDE.md). It runs `bin/claude-profiles ... --yes`, and if the utility is unavailable it follows [docs/for-claude.md](docs/for-claude.md) step by step. It tells you which steps only you can do (one terminal command, one Keychain click, pinning to the Dock).

## Install

| Method | Command |
| --- | --- |
| App (GUI + bundled CLI) | Download the DMG, drag **Claude Profiles** to Applications |
| CLI only | `zsh install.sh` (links `bin/claude-profiles` into `~/.local/bin`; override with `PREFIX=/some/dir`) |
| CLI from the app | In **Claude Profiles**, choose **Install command-line tool** (copies the tool to `~/.local/share/claude-profiles` and links `~/.local/bin/claude-profiles`; run it again after updating the app) |

### First launch (Gatekeeper)

The app is ad-hoc signed and not notarized, so macOS blocks the first launch. This is a one-time approval for this app only; you do not need to disable Gatekeeper.

1. Drag **Claude Profiles.app** from the disk image to **Applications** and open it from there (not from the disk image).
2. When macOS says it cannot verify the app, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll to **Security** and click **Open Anyway** for Claude Profiles. Then click **Open** and enter your password if asked. The button stays available for [about an hour after a blocked launch](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac); if it is missing, try opening the app again and return to that page.

On macOS 15 and later, right-click → **Open** no longer bypasses this check. Advanced alternative: `xattr -dr com.apple.quarantine "/Applications/Claude Profiles.app"`.

Verify the download against `SHA256SUMS.txt` from the same release: `shasum -a 256 -c SHA256SUMS.txt`.

The Claude copies and launchers that the tool builds on your Mac are not downloaded, so they are not quarantined and open without this step.

## Quick start

```sh
claude-profiles new --name "Work" --color '#3b82f6' --yes
claude-profiles list
claude-profiles check work
```

The wizard (`claude-profiles new` without flags) asks for the name, the color, and whether the profile is for the desktop app, the CLI or both. It also scans for existing Claude data and Claude Code history and lets you adopt them or link individual projects.

## Commands

Every interactive prompt has a flag equivalent. `--yes` means "never prompt" and is what the app and Claude Code use. Exit codes: `0` ok, `1` error, `2` usage. `--plain` output is tab-separated and never colored.

| Command | What it does |
| --- | --- |
| `new [--name N] [--slug s] [--color '#hex' \| --hue DEG \| --pick-color] [--desktop\|--no-desktop] [--cli\|--no-cli] [--data-dir P] [--config-dir P] [--dir PATH]... [--link PROJECT_CWD]... [--link-mode symlink\|move\|copy] [--no-build] [--yes] [--plain]` | Create a profile and build its app copy and launcher. `--plain` adds a final machine line `created`, the slug and the launcher path (or `-`), tab-separated. `--no-desktop` needs neither Claude.app nor a color. If the profile already exists, run `build <slug>` to retry the build. `--hue DEG` is the target hue of the icon in degrees (the tool computes the shift from the source icon), not a rotation. `--no-cli` makes a desktop-only profile (no `claude-<slug>` function, no folder rules); `--no-desktop` makes a CLI-only profile |
| `list [--plain]` | List profiles (the implicit `default` profile is included). `--plain` prints `slug`, `name`, `color`, `desktop` (`1` or `0`), `app`, `config_dir`, `data_dir`, tab-separated. For CLI-only profiles (`desktop` is `0`) `app` and `data_dir` are `-`; `color` is `-` when unset; the `default` row has color `-` |
| `scan [--plain]` | Find existing config dirs, data dirs and projects with session history. `--plain` rows are `config`, `data` and `project` lines; project dirs without a `.jsonl` transcript are left out, and config dirs without `projects/`, `.claude.json` or `settings.json` are not listed (except the main one) |
| `show <slug>` | Print one profile's settings |
| `build <slug>\|--all` | Rebuild the app copy and launcher from the current Claude.app |
| `launcher <slug>` | Rebuild only the launcher |
| `recolor <slug> [--color '#hex' \| --hue DEG \| --pick-color]` | Change the icon color in seconds, without a full rebuild (desktop profiles only; `--hue DEG` is the target hue) |
| `check <slug>` | Verify profile isolation, signature, agent and version |
| `link <slug>\|main` | Send `claude://` links (sign-in) to a profile copy for `LINK_TTL` (15 minutes by default), or back to regular Claude (desktop profiles only) |
| `remove <slug> [--delete-data] [--delete-config] [--yes]` | Remove the app copy, launcher and profile entry; data and config are kept unless asked. If `claude://` points at the removed copy it is restored to regular Claude first |
| `adopt --slug s --name N --app PATH [--launcher PATH] [--data-dir P] [--config-dir P] [--identity NAME] [--color '#hex'] [--dir PATH]...` | Register a hand-made install without rebuilding. Without `--data-dir` the default data dir must already exist |
| `setup [--identity NAME]` | One-time, terminal only: signing identity and the auto-rebuild LaunchAgent |
| `auto [--dry-run]` | What the LaunchAgent runs: rebuild stale profiles, fix wrong-profile launches |
| `uninstall-agent` | Remove the LaunchAgent |
| `shell-init zsh\|bash` | Print the shell hook: `claude`, `claude-default`, `claude-<slug>`, `claude-profile-env` (see [CLI profiles](#cli-profiles-and-shell-init)) |
| `dirs <slug> add\|rm PATH` / `dirs <slug> list` | Manage folders that auto-select a CLI profile |
| `version`, `help` | Version and usage |

### What the app does

| Menu entry | CLI equivalent |
| --- | --- |
| Create profile | `new ... --yes` |
| Change color (desktop profiles) | `recolor <slug> --color '#hex'` |
| Rebuild (desktop profiles) | `build <slug>` or `build --all` |
| Check | `check <slug>` |
| Link sign-in (claude://, desktop profiles) | `link <slug>` or `link main` |
| Remove | `remove <slug> [--delete-data] [--delete-config]` |
| Set up auto-rebuild & stable signing | installs the command-line tool, then runs `setup` from `~/.local/share/claude-profiles` in Terminal (the LaunchAgent points there, not into the app) |
| Install command-line tool | copy into `~/.local/share/claude-profiles` (without the download quarantine flag) + symlink in `~/.local/bin` |

## Updates and auto-rebuild

A profile copy is a snapshot of Claude.app. When Claude updates, the copy goes stale. `claude-profiles setup` installs one LaunchAgent that watches `/Applications/Claude.app` (plus a 15-minute timer and run-at-load) and runs `claude-profiles auto`. It:

- rebuilds every stale profile that is not running, and notifies once per Claude version for profiles that are running, so nothing is quit under you;
- reopens a copy through its launcher if it was started on the wrong profile;
- sends `claude://` links back to regular Claude after the sign-in window (`LINK_TTL`, 15 minutes by default) expires.

Every launch of a profile copy also makes the copy the default `claude://` handler, because Electron registers itself on startup. The launcher undoes that on its own about 10 seconds after a fresh launch, unless a `link <slug>` window for that profile is still open, so regular Claude keeps receiving links without the agent. The agent remains the backstop for copies started some other way.

The log is `~/Library/Logs/claude-profiles.log`.

### Stable signing

Ad-hoc signatures change on every rebuild, so macOS would ask again for Keychain access ("Claude Safe Storage") and privacy permissions after each Claude update. `setup` creates a self-signed code-signing identity (default name `Claude Profiles Signing`) in your login keychain, trusts it for code signing and lets `codesign` use it without prompts. Rebuilds then keep the same designated requirement and macOS stops asking. `setup` is interactive because it needs your login password; it must be run by you in Terminal. It is optional: without it everything works, with re-prompts after each rebuild.

## CLI profiles and shell-init

Add one line to `~/.zshrc` (or `~/.bashrc`):

```sh
eval "$(claude-profiles shell-init zsh)"
```

It defines:

- `claude`: when `CLAUDE_CONFIG_DIR` is unset and the current folder is inside a folder registered with `claude-profiles dirs <slug> add PATH`, it runs Claude Code with that profile's config dir and prints one dim line `→ profile <slug>`. `CLI_RULE_MODE` in `~/.config/claude-profiles/config.env` chooses `auto` (switch), `warn` (ask before using the default profile) or `off`.
- `claude-<slug>` for every profile that has the CLI enabled (not `--no-cli`), for example `claude-work`.
- `claude-default`, which runs Claude Code on the default config dir (`CLAUDE_CONFIG_DIR` unset) even inside a folder with a rule.
- `claude-profile-env <slug>`, which exports `CLAUDE_CONFIG_DIR` in the current shell.

The output starts with `unalias claude`, so an existing alias does not shadow the function. Set `CLAUDE_PROFILES_MODE=auto|warn|off` in the environment to override `CLI_RULE_MODE` for one shell or one command.

The hook reads only `~/.config/claude-profiles/rules.tsv`, so it adds no measurable startup cost. The CLI login is stored in the Keychain per config dir, so each profile signs in separately.

## Environment variables

| Variable | Effect |
| --- | --- |
| `CLAUDE_PROFILES_HOME` | Settings folder (default `~/.config/claude-profiles`) |
| `CLAUDE_PROFILES_LOG` | Log file (default `~/Library/Logs/claude-profiles.log`) |
| `CLAUDE_PROFILES_NO_URL_SET` | When set, the CLI never changes the `claude://` handler (for tests); it only prints what it would have done |
| `CLAUDE_PROFILES_MODE` | Shell hook only: `auto`, `warn` or `off`, overrides `CLI_RULE_MODE` |

The `claude-profiles.bak` backups: when a project is linked, edited `.claude.json` files are first copied to `<file>.claude-profiles.bak`.

## Troubleshooting

**Keychain asks for "Claude Safe Storage".** Click **Always Allow**. With the stable signing identity from `setup` this happens once; with ad-hoc signing it happens after each rebuild.

**Signing in opens the wrong app.** The `claude://` callback goes to whichever app owns the scheme. Every launch of a profile copy makes it the owner (Electron registers itself on startup), so right after launching a copy, links would go to it. The launcher gives the scheme back to regular Claude after about 10 seconds unless a `link <slug>` window is open. Run `claude-profiles link <slug>` (or **Link sign-in** in the app), sign in, then `link main`. It reverts automatically after the TTL if the LaunchAgent is installed.

**The Dock or Finder shows the old icon.** Run `killall Dock` (or `claude-profiles recolor <slug> --color <hex>`, which also refreshes Launch Services and the Dock). If it persists, restart the Dock after quitting the copy.

**I opened the copy from Spotlight/Finder and it shows my main account.** A bare launch of the copy runs it on the main data folder at the same time as the real Claude. Quit it and open the **Launcher**. With the LaunchAgent installed, `auto` detects this within moments and reopens the copy correctly.

**My window manager (StageFit, Rectangle, or any Accessibility-based tool) cannot see the copy's windows.** The copy's executable must be the real Electron binary, which this tool guarantees. A wrapper script that `exec`s the binary makes Launch Services register the app with PID 0, and accessibility clients lose track of it. If you hand-edited the copy, rebuild it with `claude-profiles build <slug>`.

**The Code tab shows no sessions in the copy.** The desktop app's session index is bound to the account and the data folder. Your transcripts are in the config dir and remain available to the CLI (`claude --resume`). See [docs/how-it-works.md](docs/how-it-works.md).

**`check` reports FAIL.** The message names the exact fix (usually: quit the copy and use the launcher, or run `link main`).

More background on every design decision is in [docs/how-it-works.md](docs/how-it-works.md).

## Uninstall

```sh
claude-profiles remove <slug>                              # one profile; keeps data and config
claude-profiles remove <slug> --delete-data --delete-config   # also delete login and history
claude-profiles uninstall-agent                            # remove the LaunchAgent
rm -f ~/.local/bin/claude-profiles                         # remove the CLI link
rm -rf ~/.config/claude-profiles                           # remove settings (optional)
```

Then delete `Claude Profiles.app` from Applications and remove the `eval "$(claude-profiles shell-init zsh)"` line from your shell config. The signing identity can be deleted in Keychain Access (search for "Claude Profiles Signing").

## Security notes

- **Self-signed identity.** `setup` creates a self-signed code-signing certificate in your login keychain, trusts it for code signing (this is what asks for your password) and adds `codesign` to the private key's partition list so signing runs without prompts. Only this identity name is trusted, nothing else is added to the keychain. Identity names may use only letters, digits, space, dot, underscore and dash.
- **Source Team ID check.** Before `build` or `auto` copies `/Applications/Claude.app`, the tool verifies that it is signed by Apple Team ID `Q6L2SF6YDW` (`SOURCE_TEAM_ID` in `config.env`; an empty value disables the check). `build` stops with an error and `auto` logs the refusal and skips the copy.
- **LaunchAgent path.** The LaunchAgent runs `claude-profiles` from the path it was installed from. `setup` refuses to install it from a disk image, a translocated app, or any location that is not owned by you or is writable by group or others. Install the CLI or the app in a user-owned location (for example `~/.local/bin` or `/Applications` installed by you), then run `setup`.
- **No hardened runtime.** Profile copies are re-signed without the hardened runtime, like the hand-made reference setup, and keep the sanitized entitlements of the original. They are as trusted as the Claude.app they were copied from.
- **Deleting data.** `remove --delete-data` and `--delete-config` only delete folders under your home whose name starts with `.claude` or `Claude-`, and never `~/.claude`, the main Claude data folder or the source app.

## Safety

Nothing here modifies `/Applications/Claude.app`, and it never reads or prints your credentials. Profile copies are separate apps; deleting one never touches the original. Removing a profile keeps its data and config folders unless you pass the explicit flags.

## License

MIT, see [LICENSE](LICENSE).
