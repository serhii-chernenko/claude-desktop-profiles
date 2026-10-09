# claude-desktop-profiles

Utility to run several Claude accounts on macOS (desktop copies with their own data dir and icon, CLI profiles via `CLAUDE_CONFIG_DIR`). Layout and facts: [docs/how-it-works.md](docs/how-it-works.md).

## When the user asks for a profile (create, recolor, rebuild, check, link, remove)

1. Prefer the CLI, always non-interactive: `bin/claude-profiles <command> ... --yes`. Run `bin/claude-profiles help` for the flags and `bin/claude-profiles list --plain` / `scan --plain` to inspect state.
2. If the CLI fails or is missing, follow [docs/for-claude.md](docs/for-claude.md) step by step.
3. Finish by listing the steps only the human can do: pin the launcher to the Dock, sign in, click **Always Allow** on the Keychain prompt, optionally run `setup` in Terminal.

## Rules

- Never run `setup` (or its `security`/`launchctl` steps) for the user. It needs their password; tell them to run `bin/claude-profiles setup` in their own terminal.
- Ask before quitting a running Claude copy and before moving, copying over or deleting session history, config dirs or data dirs.
- Never modify `/Applications/Claude.app`, the keychain, or LaunchAgents by hand.
- Do not edit shell startup files without asking.

## Development rules

- Zero runtime dependencies: only tools that ship with macOS. No ImageMagick, Swift or Python.
- No inline code comments. Short usage header blocks at the top of scripts are fine. Put explanations in `docs/`.
- No personal names, paths or bundle IDs in the repository: use `~`, `$HOME` and generic examples such as "Work".
- Check scripts with `zsh -n`. The GUI applet source is `gui/Claude Profiles.applescript`; verify it with `osacompile`, and do not launch it from automation (it shows dialogs).
- Build output goes to `dist/` only: `zsh scripts/build-app.sh`, `zsh scripts/build-dmg.sh`.
