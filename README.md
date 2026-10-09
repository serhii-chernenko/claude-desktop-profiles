# claude-desktop-profiles

Run several Claude accounts side by side on macOS, each with its own login, its own Dock icon and its own Claude Code history. Profile names are yours: nothing is hardcoded.

- **Claude desktop**: every profile is a copy of `/Applications/Claude.app` with its own bundle ID, its own data folder and a tinted icon. A small launcher app starts the copy on the right data folder. The copy is kept in the hidden folder `/Applications/.claude-profiles`, so Spotlight and Raycast show **only one entry per profile**: `Claude <Name>`, which is the launcher.
- **Claude Code (CLI)**: every profile has its own `CLAUDE_CONFIG_DIR`. A shell hook picks the profile from the folder you are in.
- **Native app, no dependencies**: Claude Profiles is a SwiftUI window over a zsh command-line tool. It needs only what ships with macOS (zsh, `osascript`, PlistBuddy, `codesign`, `iconutil`, `ditto`, `security`, `launchctl`). No Homebrew packages, no Python.

Requires macOS 13 or newer. Desktop profiles also need an installed `/Applications/Claude.app`; Claude Code (CLI) profiles work without it.

## Three ways to use it

1. **The app** (recommended): a window to create, recolor, check and remove profiles.
2. **The command-line tool**: the same operations as `claude-profiles`, for scripts and power users.
3. **Claude Code**: ask it in this repository and it drives the command-line tool for you.

## Path 1: the app

### Install

1. Download `Claude-Profiles-<version>.dmg` from the [Releases](https://github.com/serhii-chernenko/claude-desktop-profiles/releases) page and drag **Claude Profiles** to **Applications**.
2. Open it from Applications and approve it once with **Open Anyway** (see [First launch](#first-launch-gatekeeper)).
3. Use the window. Pin the new **Claude `<Name>`** (the launcher, in `/Applications`) to the Dock and always start a profile through it. The app copy itself is hidden in `/Applications/.claude-profiles`.

### The window

- **Sidebar.** Your profiles, then **Main Claude** (your regular app and `~/.claude`, read-only: profiles never change it) and **Setup & Settings**. **New Profile** is at the bottom (or press ⌘N).
- **Create a profile.** Give it a name, pick an **icon color** with the color picker (the tint is applied to the copy's Dock icon and its launcher), and choose what it is for: the desktop app, Claude Code, or both. You can reuse an existing data folder (which keeps its sign-in and chats) or config folder, bring existing projects along (share, move or copy, see below) and list folders that select the profile automatically.
- **A profile page** has the color picker (recolor takes seconds, no rebuild), **Open**, **Move to New Layout** (only for profiles that still use the old layout, see [Where the apps live](#where-the-apps-live)), **Rebuild**, **Check**, **Link Sign-in** / **Back to Main** (sends `claude://` sign-in links to the profile for a while, then back), **Copy Command** (the `claude-<slug>` command), **Remove** (keeps data and history unless you tick the delete boxes), the folders that auto-select the profile, and its Claude Code projects.
- **Adopt banner.** If the app finds a copy you built by hand earlier (a `Claude <Name>.app` with its own data folder), it shows a banner "Found existing copy". **Adopt** manages it here without rebuilding or changing it; **Not Now** hides the banner.
- **Project migration.** In a profile, **Add Projects** lists Claude Code projects that have history in other config folders. For the ones you tick, choose **Share** (a symlink: both config folders see the same history from now on), **Move** (the history leaves the old config folder) or **Copy** (an independent copy). You can also add each project folder to the profile's folders so `claude` picks the profile there. Quit Claude Code sessions in those projects first.
- **Setup & Settings.**
  - **Command-line tool**: **Install** (or **Update**) copies the tool bundled in the app to `~/.local/share/claude-profiles` and links `~/.local/bin/claude-profiles`, so `claude-profiles` works in Terminal.
  - **Shell integration**: a toggle that adds (or removes) one marked line in `~/.zshrc` (or `~/.bashrc`) that defines `claude`, `claude-default` and `claude-<profile>`. It warns about other definitions of `claude` that would override it.
  - **Updates and signing**: the status of the signing identity, the auto-rebuild agent and Claude.app. **Set Up** installs the command-line tool and opens Terminal once to run `setup`; you type your login password there, and the app never sees it.
  - **Old LaunchAgents**: lists agents from earlier hand-made setups that also watch Claude.app. **Disable** unloads one and renames its file to `.disabled`; nothing is deleted.

Every button runs a `claude-profiles` command: see [What the app does](#what-the-app-does) and the [command reference](#commands). **Show Log** displays the output.

### First launch (Gatekeeper)

The app is ad-hoc signed and not notarized, so macOS blocks the first launch. This is a one-time approval for this app only; you do not need to disable Gatekeeper.

1. Drag **Claude Profiles.app** from the disk image to **Applications** and open it from there (not from the disk image).
2. When macOS says it cannot verify the app, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll to **Security** and click **Open Anyway** for Claude Profiles. Then click **Open** and enter your password if asked. The button stays available for [about an hour after a blocked launch](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac); if it is missing, try opening the app again and return to that page.

On macOS 15 and later, right-click → **Open** no longer bypasses this check. Advanced alternative: `xattr -dr com.apple.quarantine "/Applications/Claude Profiles.app"`.

Verify the download against `SHA256SUMS.txt` from the same release: `shasum -a 256 -c SHA256SUMS.txt`.

The Claude copies and launchers that the tool builds on your Mac are not downloaded, so they are not quarantined and open without this step. The command-line tool that the app installs is copied without the quarantine flag as well.

## Path 2: the command-line tool

For power users and scripts. Get it from the app (**Setup & Settings → Command-line tool → Install**), or clone this repository and run `zsh install.sh` (links `bin/claude-profiles` into `~/.local/bin`; override with `PREFIX=/some/dir`).

```sh
claude-profiles new --name "Work" --color '#3b82f6' --yes
claude-profiles list
claude-profiles check work
claude-profiles shell-init install
```

The wizard (`claude-profiles new` without flags) asks for the name, the color, and whether the profile is for the desktop app, the CLI or both. It also scans for existing Claude data and Claude Code history and lets you adopt them or link individual projects. Then pin the new launcher to the Dock and run `claude-profiles setup` once in Terminal (see [Updates and auto-rebuild](#updates-and-auto-rebuild)).

## Path 3: ask Claude Code

1. Clone this repository and open Claude Code in it:

   ```sh
   git clone https://github.com/serhii-chernenko/claude-desktop-profiles.git
   cd claude-desktop-profiles
   claude
   ```

2. Say: "Create a profile called Work."
3. Claude Code follows [CLAUDE.md](CLAUDE.md). It runs `bin/claude-profiles ... --yes`, and if the utility is unavailable it follows [docs/for-claude.md](docs/for-claude.md) step by step. It never runs `setup` for you: that always happens in your own Terminal, because it needs your password. It also tells you the other steps only you can do (one Keychain click, pinning to the Dock).

## Commands

Every interactive prompt has a flag equivalent. `--yes` means "never prompt" and is what the app and Claude Code use. Exit codes: `0` ok, `1` error, `2` usage. `--plain` output is tab-separated and never colored.

| Command | What it does |
| --- | --- |
| `new [--name N] [--slug s] [--color '#hex' \| --hue DEG \| --pick-color] [--desktop\|--no-desktop] [--cli\|--no-cli] [--data-dir P] [--config-dir P] [--dir PATH]... [--link PROJECT_CWD]... [--link-mode symlink\|move\|copy] [--no-build] [--yes] [--plain]` | Create a profile and build its app copy and launcher. `--plain` adds a final machine line `created`, the slug and the launcher path (or `-`), tab-separated. `--no-desktop` needs neither Claude.app nor a color. If the profile already exists, run `build <slug>` to retry the build. `--hue DEG` is the target hue of the icon in degrees (at the source icon's own saturation and brightness), not a rotation. `--no-cli` makes a desktop-only profile (no `claude-<slug>` function, no folder rules); `--no-desktop` makes a CLI-only profile |
| `list [--plain]` | List profiles (the implicit `default` profile is included). `--plain` prints `slug`, `name`, `color`, `desktop` (`1` or `0`), `app`, `config_dir`, `data_dir`, tab-separated. For CLI-only profiles (`desktop` is `0`) `app` and `data_dir` are `-`; `color` is `-` when unset; the `default` row has color `-` |
| `scan [--plain]` | Find existing config dirs, data dirs and projects with session history. Copies are looked up in `APPS_DIR` and `/Applications`, with either layout of launcher. `--plain` rows are `config`, `data` and `project` lines; project dirs without a `.jsonl` transcript are left out, and config dirs without `projects/`, `.claude.json` or `settings.json` are not listed (except the main one) |
| `show <slug> [--plain]` | Print one profile's settings. `--plain` prints `key<TAB>value` lines, then one `dir` line per folder. The `layout` line is `legacy` (copy and launcher both in `/Applications`) or `hidden` (copy in `APPS_DIR`), and `-` for CLI-only profiles |
| `projects <slug> list [--plain]` | Claude Code session history stored in the profile's config dir, by project folder. `--plain` rows: `project`, working directory, sessions, last used, `symlink` or `dir` |
| `projects <slug> add [--mode symlink\|move\|copy] [--no-dir] [--yes] CWD...` | Bring the history of project folders into an **existing** profile (the same operation as `--link` on `new`). `symlink` shares it, `move` reassigns it, `copy` duplicates it. By default each folder is also added to the profile's folders; `--no-dir` skips that. Quit running Claude Code sessions in those projects first |
| `status [--plain]` | Command-line tool install, signing identity, auto-rebuild agent, source app and the `claude://` handler, with the settings folder |
| `install-cli [--from DIR] [--prefix DIR] [--share-dir DIR] [--bin-dir DIR]` | Copy the tool (without the quarantine flag) to `~/.local/share/claude-profiles` and link `~/.local/bin/claude-profiles` |
| `legacy-agents [--plain]` | List other LaunchAgents that watch Claude.app or a profile copy (earlier hand-made setups) |
| `legacy-agents disable LABEL [--yes]` | Unload one of them and rename its plist to `.disabled`; nothing is deleted |
| `build <slug>\|--all` | Rebuild the app copy and launcher from the current Claude.app. A profile in the old layout is moved to the new one first (if an old LaunchAgent blocks the move, the build warns and stays in the old layout) |
| `migrate-layout <slug> [--yes] [--plain]` | Move a profile from the old layout to the new one: the copy goes into `APPS_DIR`, the old `… Launcher.app` is removed and the launcher is rebuilt as `/Applications/Claude <Name>.app`. Refuses while the copy runs, and exits 3 while a legacy LaunchAgent references the copy or Claude.app (`--plain` prints its `agent` rows; stderr names what to `legacy-agents disable`). Re-pin the launcher in the Dock afterwards |
| `launcher <slug>` | Rebuild only the launcher (refuses to sign it ad-hoc over an identity-signed copy) |
| `resign <slug>` | Quick repair of a mixed signature: re-sign only the outer bundle and the launcher with the profile's resolved signing identity; nested code is left untouched |
| `set <slug> sign-identity NAME\|--clear` | Pin the code-signing certificate used for one profile (`--clear` goes back to automatic) |
| `recolor <slug> [--color '#hex' \| --hue DEG \| --pick-color]` | Change the icon color in seconds, without a full rebuild (desktop profiles only). The dominant color of the icon becomes exactly the chosen color; `--hue DEG` is the target hue at the original saturation and brightness. The outer bundle is re-signed with the profile's identity |
| `check <slug>` | Verify profile isolation, layout, signature, agent and version. WARN for the old layout (fix: `migrate-layout`), FAIL if the launcher path is the copy itself. An ad-hoc outer bundle over identity-signed nested code is reported as FAIL with the fix (`resign`) |
| `link <slug>\|main` | Send `claude://` links (sign-in) to a profile copy for `LINK_TTL` (15 minutes by default), or back to regular Claude (desktop profiles only) |
| `remove <slug> [--delete-data] [--delete-config] [--yes]` | Remove the app copy, launcher and profile entry; data and config are kept unless asked. If `claude://` points at the removed copy it is restored to regular Claude first |
| `adopt --slug s --name N --app PATH [--launcher PATH] [--data-dir P] [--config-dir P] [--identity NAME] [--color '#hex'] [--dir PATH]...` | Register a hand-made install without rebuilding. Either layout is accepted (copy in `APPS_DIR` with a launcher in `/Applications`, or both in `/Applications`); without `--launcher` the launcher is looked up next to the copy (`… Launcher.app`) and in `/Applications` under the copy's name. Without `--data-dir` the default data dir must already exist. `scan` lists hand-made copies it finds as `candidate` rows (the last column is the signing identity found in the copy, or `-`), ready to adopt. Adopt keeps the identity the copy is signed with (stored per profile as `PROFILE_SIGN_IDENTITY`); `--identity NAME` overrides it |
| `setup [--identity NAME]` | One-time, terminal only: signing identity and the auto-rebuild LaunchAgent |
| `auto [--dry-run]` | What the LaunchAgent runs: rebuild stale profiles, fix wrong-profile launches |
| `uninstall-agent` | Remove the LaunchAgent |
| `shell-init zsh\|bash` | Print the shell hook: `claude`, `claude-default`, `claude-<slug>`, `claude-profile-env` (see [CLI profiles](#cli-profiles-and-shell-init)) |
| `shell-init install [zsh\|bash] [--rc FILE]` | Add the `eval "$(claude-profiles shell-init zsh)"` line to `~/.zshrc` or `~/.bashrc` as one marked, idempotent block (a backup is kept) |
| `shell-init uninstall [zsh\|bash] [--rc FILE]` | Remove that block |
| `shell-init status [zsh\|bash] [--rc FILE] [--plain]` | Whether the block is installed (`installed` 0 or 1), and any other definitions of `claude` that would override it |
| `dirs <slug> add\|rm PATH` / `dirs <slug> list` | Manage folders that auto-select a CLI profile |
| `version`, `help` | Version and usage |

### What the app does

| In the app | CLI equivalent |
| --- | --- |
| New Profile | `new ... --yes` |
| Icon color (desktop profiles) | `recolor <slug> --color '#hex'` |
| Rebuild (desktop profiles) | `build <slug>` or `build --all` |
| Move to New Layout (old-layout profiles) | `migrate-layout <slug> --yes --plain` (the `agent` rows of a blocked run list the agents to disable) |
| Check | `check <slug>` |
| Link Sign-in / Back to Main (desktop profiles) | `link <slug>` or `link main` |
| Remove | `remove <slug> [--delete-data] [--delete-config]` |
| Adopt banner | `scan --plain` (the `candidate` rows), then `adopt ...` |
| Add Projects | `projects <slug> add --mode symlink\|move\|copy CWD...`; the list comes from `scan --plain` and `projects <slug> list --plain` |
| Settings: Command-line tool | `install-cli` and `status` |
| Settings: Shell integration | `shell-init install`, `shell-init uninstall` and `shell-init status` |
| Settings: Set Up | `install-cli`, then Terminal opens and runs `setup` from `~/.local/share/claude-profiles` (the LaunchAgent points there, not into the app) |
| Settings: Old LaunchAgents | `legacy-agents` and `legacy-agents disable LABEL` |

## Where the apps live

Each desktop profile has two apps:

| App | Path | Purpose |
| --- | --- | --- |
| The copy | `$APPS_DIR/Claude <Name>.app` (default `APPS_DIR` is `/Applications/.claude-profiles`) | The real Claude copy. It is registered with Launch Services but sits in a dot-folder, which Spotlight does not index and Finder hides, so it never shows up in search |
| The launcher | `/Applications/Claude <Name>.app` | Named exactly like the profile, bundle ID `<copy bundle ID>.launcher`. It is the only entry in Spotlight and Raycast, and the app to pin to the Dock |

The copy's own name stays `Claude <Name>`, so the Dock and ⌘-Tab show the same name while it runs. The launcher finds the copy by bundle ID, not by path. `APPS_DIR` is a key in `~/.config/claude-profiles/config.env`.

Older versions put both apps in `/Applications`, as `Claude <Name>.app` and `Claude <Name> Launcher.app`. Move such a profile with `claude-profiles migrate-layout <slug>` (or **Move to New Layout** in the app); `build` does the same move first when it finds the old layout. The move keeps the copy's signature and designated requirement (nothing is rebuilt or re-signed), so Keychain and privacy permissions stay as they are. It refuses while the copy is running, and while an old LaunchAgent references the copy or Claude.app (it would recreate the copy at the old path): disable it first, see `legacy-agents`. **After the move, re-pin the launcher in the Dock**: the old Dock item pointed at the removed `… Launcher.app`.

## Updates and auto-rebuild

A profile copy is a snapshot of Claude.app. When Claude updates, the copy goes stale. `claude-profiles setup` installs one LaunchAgent that watches `/Applications/Claude.app` (plus a 15-minute timer and run-at-load) and runs `claude-profiles auto`. It:

- rebuilds every stale profile that is not running, and notifies once per Claude version for profiles that are running, so nothing is quit under you;
- reopens a copy through its launcher if it was started on the wrong profile;
- sends `claude://` links back to regular Claude after the sign-in window (`LINK_TTL`, 15 minutes by default) expires.

Every launch of a profile copy also makes the copy the default `claude://` handler, because Electron registers itself on startup. The launcher undoes that on its own about 10 seconds after a fresh launch, unless a `link <slug>` window for that profile is still open, so regular Claude keeps receiving links without the agent. The agent remains the backstop for copies started some other way.

The log is `~/Library/Logs/claude-profiles.log`.

### Stable signing

Ad-hoc signatures change on every rebuild, so macOS would ask again for Keychain access ("Claude Safe Storage") and privacy permissions after each Claude update. `setup` creates a self-signed code-signing identity (default name `Claude Profiles Signing`) in your login keychain, trusts it for code signing and lets `codesign` use it without prompts. Rebuilds then keep the same designated requirement and macOS stops asking. `setup` is interactive because it needs your login password; it must be run by you in Terminal. It is optional: without it everything works, with re-prompts after each rebuild.

The identity is chosen per profile: the one set with `set <slug> sign-identity` (or `adopt --identity`), else the one that already signs the copy's nested code, else the global one from `setup`, else ad-hoc. If the chosen identity cannot sign (locked keychain), `build`, `recolor` and `launcher` stop instead of mixing an ad-hoc outer signature with identity-signed helpers. Details: [docs/how-it-works.md](docs/how-it-works.md).

## CLI profiles and shell-init

Turn on **Shell integration** in the app, or run `claude-profiles shell-init install` (it adds one marked block to `~/.zshrc` or `~/.bashrc`; `shell-init uninstall` removes it). By hand, add this line to your shell startup file:

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
| `CLAUDE_PROFILES_APPS_DIR` | Overrides `APPS_DIR`, the folder for the app copies (default `/Applications/.claude-profiles`, or the `APPS_DIR` key of `config.env`). For tests |
| `CLAUDE_PROFILES_LAUNCHER_DIR` | Folder for the launchers (default `/Applications`). For tests |
| `CLAUDE_PROFILES_AGENTS_DIR` | Folder scanned for old LaunchAgents (default `~/Library/LaunchAgents`). For tests |
| `CLAUDE_PROFILES_NO_URL_SET` | When set, the CLI never changes the `claude://` handler (for tests); it only prints what it would have done |
| `CLAUDE_PROFILES_MODE` | Shell hook only: `auto`, `warn` or `off`, overrides `CLI_RULE_MODE` |

The `claude-profiles.bak` backups: when a project is linked, edited `.claude.json` files are first copied to `<file>.claude-profiles.bak`.

## Troubleshooting

**Keychain asks for "Claude Safe Storage".** Click **Always Allow**. With the stable signing identity from `setup` this happens once; with ad-hoc signing it happens after each rebuild.

**Keychain or permission prompts come back after `recolor` (or `check` says "mixed signature").** The outer app was signed ad-hoc while its helpers still carry a certificate, which changes the app's identity for macOS. Run `claude-profiles check <slug>`; if it names a mixed signature, unlock the login keychain and run `claude-profiles resign <slug>` (add `claude-profiles set <slug> sign-identity "<Something> Signing"` first if the certificate is not detected). `recolor` and `launcher` now refuse to create this state; `adopt` keeps the signature of the copy it registers.

**The icon color differs from the one I picked.** Fixed: the icon is now remapped so its dominant color equals the picked color (hue, saturation and brightness), within a few steps out of 255. Run `claude-profiles recolor <slug> --color '#hex'` once to re-apply it to a copy tinted by an older version.

**Signing in opens the wrong app.** The `claude://` callback goes to whichever app owns the scheme. Every launch of a profile copy makes it the owner (Electron registers itself on startup), so right after launching a copy, links would go to it. The launcher gives the scheme back to regular Claude after about 10 seconds unless a `link <slug>` window is open. Run `claude-profiles link <slug>` (or **Link sign-in** in the app), sign in, then `link main`. It reverts automatically after the TTL if the LaunchAgent is installed.

**The Dock or Finder shows the old icon.** Run `killall Dock` (or `claude-profiles recolor <slug> --color <hex>`, which also refreshes Launch Services and the Dock). If it persists, restart the Dock after quitting the copy.

**I opened the copy from Spotlight/Finder and it shows my main account.** A bare launch of the copy runs it on the main data folder at the same time as the real Claude. Quit it and open the launcher (`Claude <Name>`). In the new layout the copy is hidden from search, so this mostly happens through `claude://` links or session restore. With the LaunchAgent installed, `auto` detects this within moments and reopens the copy correctly.

**My window manager (StageFit, Rectangle, or any Accessibility-based tool) cannot see the copy's windows.** The copy's executable must be the real Electron binary, which this tool guarantees. A wrapper script that `exec`s the binary makes Launch Services register the app with PID 0, and accessibility clients lose track of it. If you hand-edited the copy, rebuild it with `claude-profiles build <slug>`.

**The Code tab shows no sessions in the copy.** The desktop app's session index is bound to the account and the data folder. Your transcripts are in the config dir and remain available to the CLI (`claude --resume`). See [docs/how-it-works.md](docs/how-it-works.md).

**macOS says Claude Profiles "cannot be opened" or "is damaged".** The app is not notarized, so the first launch needs **Open Anyway** (see [First launch](#first-launch-gatekeeper)). Open it from Applications, not from the disk image.

**Set Up opens Terminal and `setup` stops with "disk image or translocated app".** Move **Claude Profiles.app** to Applications, open it from there and press **Set Up** again. It installs the command-line tool first, and `setup` runs from that installed copy.

**Shell integration is on but `claude` does not pick the profile.** Another definition of `claude` (an alias or function in a shell startup file) overrides it. The Settings tab, or `claude-profiles shell-init status`, shows where; remove or rename it, then open a new Terminal window.

**Search shows two entries per profile, or the Dock item stopped working.** The profile still uses the old layout (`show <slug>` prints `layout legacy`; `check` warns): run `claude-profiles migrate-layout <slug>`, then remove the old Dock item and pin `Claude <Name>` again. If it stops with an old LaunchAgent, disable that agent first (`claude-profiles legacy-agents`).

**Old hand-made LaunchAgents rebuild or quit my copies.** List them with `claude-profiles legacy-agents` (or in Settings) and disable them one by one with `legacy-agents disable LABEL`.

**`check` reports FAIL.** The message names the exact fix (usually: quit the copy and use the launcher, or run `link main`).

More background on every design decision is in [docs/how-it-works.md](docs/how-it-works.md).

## Uninstall

```sh
claude-profiles remove <slug>                              # one profile; keeps data and config
claude-profiles remove <slug> --delete-data --delete-config   # also delete login and history
claude-profiles uninstall-agent                            # remove the LaunchAgent
claude-profiles shell-init uninstall                       # remove the shell hook block
rm -f ~/.local/bin/claude-profiles                         # remove the CLI link
rm -rf ~/.local/share/claude-profiles                      # remove the installed CLI copy
rm -rf ~/.config/claude-profiles                           # remove settings (optional)
```

Then delete `Claude Profiles.app` from Applications. The signing identity can be deleted in Keychain Access (search for "Claude Profiles Signing").

## Security notes

- **Self-signed identity.** `setup` creates a self-signed code-signing certificate in your login keychain, trusts it for code signing (this is what asks for your password) and adds `codesign` to the private key's partition list so signing runs without prompts. Only this identity name is trusted, nothing else is added to the keychain. Identity names may use only letters, digits, space, dot, underscore and dash.
- **Source Team ID check.** Before `build` or `auto` copies `/Applications/Claude.app`, the tool verifies that it is signed by Apple Team ID `Q6L2SF6YDW` (`SOURCE_TEAM_ID` in `config.env`; an empty value disables the check). `build` stops with an error and `auto` logs the refusal and skips the copy.
- **LaunchAgent path.** The LaunchAgent runs `claude-profiles` from the path it was installed from. `setup` refuses to install it from a disk image, a translocated app, or any location that is not owned by you or is writable by group or others. Run `install-cli` first (the app's **Set Up** button does it for you), so the tool lives in `~/.local/share/claude-profiles`: a user-owned location without the quarantine flag. Then run `setup` from there.
- **No hardened runtime.** Profile copies are re-signed without the hardened runtime, like the hand-made reference setup, and keep the sanitized entitlements of the original. They are as trusted as the Claude.app they were copied from.
- **Deleting data.** `remove --delete-data` and `--delete-config` only delete folders under your home whose name starts with `.claude` or `Claude-`, and never `~/.claude`, the main Claude data folder or the source app.

## Safety

Nothing here modifies `/Applications/Claude.app`, and it never reads or prints your credentials. Profile copies are separate apps; deleting one never touches the original. Removing a profile keeps its data and config folders unless you pass the explicit flags.

## License

MIT, see [LICENSE](LICENSE).
