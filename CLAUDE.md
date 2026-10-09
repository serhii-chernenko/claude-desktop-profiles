# claude-desktop-profiles

Utility to run several Claude accounts on macOS (desktop copies with their own data dir and icon, CLI profiles via `CLAUDE_CONFIG_DIR`). It ships as a native SwiftUI app (`Sources/ClaudeProfiles`) that is a thin shell over the bundled CLI (`bin/claude-profiles`). Layout and facts: [docs/how-it-works.md](docs/how-it-works.md).

## When the user asks for a profile (create, recolor, rebuild, check, link, remove)

1. Prefer the CLI, always non-interactive: `bin/claude-profiles <command> ... --yes`. Run `bin/claude-profiles help` for the flags and `bin/claude-profiles list --plain` / `scan --plain` / `status --plain` to inspect state.
2. Existing material:
   - `projects <slug> add --mode symlink|move|copy CWD...` brings Claude Code history into an existing profile;
   - `adopt` registers a hand-made copy that `scan --plain` reports as a `candidate`;
   - `shell-init install` adds the shell hook to `~/.zshrc` (ask first);
   - `legacy-agents` lists old LaunchAgents that watch Claude.app.
3. If the CLI fails or is missing, follow [docs/for-claude.md](docs/for-claude.md) step by step.
4. Finish by listing the steps only the human can do: pin the launcher to the Dock, sign in, click **Always Allow** on the Keychain prompt, and run `setup` in Terminal.

## Rules

- Never run `setup` (or its `security`/`launchctl` steps) for the user. It needs their password and is always run by the human in Terminal: tell them to run `claude-profiles setup` (or press **Set Up** in the app, which opens Terminal).
- Ask before quitting a running Claude copy and before moving, copying over or deleting session history, config dirs or data dirs.
- Never modify `/Applications/Claude.app`, the keychain, or LaunchAgents by hand.
- Do not edit shell startup files without asking; `shell-init install` counts.

## Development rules

- The CLI has zero runtime dependencies: only tools that ship with macOS. No ImageMagick or Python. The app is built with `swiftc` from the Xcode Command Line Tools, with no Swift packages.
- No inline code comments. Short usage header blocks at the top of scripts are fine. Put explanations in `docs/`.
- No personal names, paths or bundle IDs in the repository: use `~`, `$HOME` and generic examples such as "Work".
- Check scripts with `zsh -n`. Never launch the built app from automation (it shows windows); `ClaudeProfiles --self-test` is headless and runs as part of `scripts/build-app.sh`.
- The CLI's `--plain` output is the contract the app parses: change it in `bin/claude-profiles` and `Sources/ClaudeProfiles/PlainParser.swift` together.
- Build output goes to `dist/` only: `zsh scripts/build-app.sh`, `zsh scripts/build-dmg.sh`.
