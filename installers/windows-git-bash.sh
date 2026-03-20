#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_SOURCE="$SCRIPT_DIR/src/validate.sh"

if [[ ! -f "$VALIDATE_SOURCE" ]]; then
  echo "error: cannot find $VALIDATE_SOURCE" >&2
  exit 1
fi

TARGET_DIR="$HOME/bin"
TARGET_PATH="$TARGET_DIR/validate"

mkdir -p "$TARGET_DIR"
cp "$VALIDATE_SOURCE" "$TARGET_PATH"
chmod +x "$TARGET_PATH"

BASHRC="$HOME/.bashrc"
BASH_PROFILE="$HOME/.bash_profile"

append_bashrc() {
  if [[ ! -f "$BASHRC" ]]; then
    touch "$BASHRC"
  fi

  if ! grep -Fq 'export PATH="$HOME/bin:$PATH"' "$BASHRC"; then
    cat <<'EOF' >> "$BASHRC"

# Ensure ~/.bin is on PATH for sf-validate helper
export PATH="$HOME/bin:$PATH"
EOF
  fi
}

append_bash_profile() {
  if [[ -f "$BASH_PROFILE" ]] && ! grep -Fq 'source ~/.bashrc' "$BASH_PROFILE"; then
    cat <<'EOF' >> "$BASH_PROFILE"

# Load .bashrc so the updated PATH is available
if [ -f ~/.bashrc ]; then
  source ~/.bashrc
fi
EOF
  fi
}

append_bashrc
append_bash_profile

echo "Installed sf-validate to $TARGET_PATH"
echo "Run 'source ~/.bashrc' (or restart Git Bash) to refresh your PATH if needed."
