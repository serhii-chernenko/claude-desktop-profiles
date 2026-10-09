#!/bin/zsh
# Symlinks bin/claude-profiles into ${PREFIX:-~/.local/bin} and prints the shell hook.
#
#   zsh install.sh
#   PREFIX=/usr/local/bin zsh install.sh
set -euo pipefail

ROOT=${0:A:h}
TARGET_DIR="${PREFIX:-$HOME/.local/bin}"
SOURCE="$ROOT/bin/claude-profiles"
LINK="$TARGET_DIR/claude-profiles"

[[ -f $SOURCE ]] || { print -u2 "ERROR: $SOURCE not found"; exit 1; }
chmod +x "$SOURCE"
mkdir -p "$TARGET_DIR"
ln -sfn "$SOURCE" "$LINK"
print "Linked: $LINK -> $SOURCE"

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) print -u2 "WARN:  $TARGET_DIR is not on your PATH. Add this to ~/.zshrc: export PATH=\"$TARGET_DIR:\$PATH\"" ;;
esac

print "\nAdd this line to ~/.zshrc for claude-<profile> aliases and folder-based profile selection:"
print "  eval \"\$(claude-profiles shell-init zsh)\""
