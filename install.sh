#!/usr/bin/env bash
# install.sh — install the Claude Skills Toolkit into ~/.claude
#
# Copies each skill into ~/.claude/skills/<name>/ and installs the recommended
# user CLAUDE.md. Idempotent and non-destructive:
#   - an existing skill directory is backed up to <name>.bak-<timestamp> first
#   - an existing ~/.claude/CLAUDE.md is never overwritten; the recommended
#     version is written alongside as CLAUDE.md.recommended
# Per-project setup (.agent.env, project settings) is printed at the end, not
# applied — those belong to each project, not to ~/.claude.
#
# Override the target root with CLAUDE_HOME (default: ~/.claude).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_DIR/skills"

stamp="$(date +%Y%m%d%H%M%S)"

echo "Installing Claude Skills Toolkit into $SKILLS_DIR"
mkdir -p "$SKILLS_DIR"

# Every directory under skills/ installs as ~/.claude/skills/<name>/.
for src in "$REPO_DIR"/skills/*/; do
  name="$(basename "$src")"
  dest="$SKILLS_DIR/$name"
  if [[ -e "$dest" ]]; then
    backup="$dest.bak-$stamp"
    echo "  ~ backing up existing $name -> $(basename "$backup")"
    mv "$dest" "$backup"
  fi
  mkdir -p "$dest"
  cp -R "$src." "$dest/"
  if [[ -d "$dest/scripts" ]]; then
    find "$dest/scripts" -type f -name '*.sh' -exec chmod +x {} +
  fi
  echo "  + $name"
done

# Recommended user CLAUDE.md — never clobber an existing one.
example_claude="$REPO_DIR/user-claude-md/CLAUDE.md"
if [[ -f "$example_claude" ]]; then
  if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]]; then
    cp "$example_claude" "$CLAUDE_DIR/CLAUDE.md.recommended"
    echo "  ~ ~/.claude/CLAUDE.md exists; wrote recommended version to CLAUDE.md.recommended"
  else
    cp "$example_claude" "$CLAUDE_DIR/CLAUDE.md"
    echo "  + installed recommended ~/.claude/CLAUDE.md"
  fi
fi

cat <<EOF

Done. Per-project setup (run in each project that uses the skills):

  1. Copy the env template and fill in values:
       cp "$REPO_DIR/project-files/.agent.env" <your-project>/.agent.env

  2. Adopt the permission allowlist by merging this into the project's
     .claude/settings.json:
       $REPO_DIR/project-files/.claude/settings.json

Skills installed to: $SKILLS_DIR
EOF
