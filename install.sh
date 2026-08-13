#!/usr/bin/env bash
# install.sh — install the Claude Skills Toolkit into ~/.claude
#
# This is the clone-and-copy route. The other route is the plugin marketplace
# (`/plugin marketplace add LunarCommand/claude-skills`), which installs the
# same skills individually with versioning and updates. Either works; the
# difference is that marketplace skills are namespaced (/hyperdx:hyperdx) while
# these are not (/hyperdx).
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
  # bin/ is what Claude Code puts on the Bash tool's PATH, so these must stay
  # executable for the skills to invoke them by bare name.
  if [[ -d "$dest/bin" ]]; then
    find "$dest/bin" -type f -name '*.sh' -exec chmod +x {} +
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

  2. Adopt the permission allowlist by merging the "permissions" block from:
       $REPO_DIR/project-files/.claude/settings.json

     Into a project's .claude/settings.json to approve the scripts there, or
     into ~/.claude/settings.json to approve them everywhere. The scripts are
     on the Bash tool's PATH, so the rules approve them by bare name —
     Bash(hdx_query.sh:*) and friends — which holds for both install routes and
     survives updates. Without this, every script call prompts.

  3. Check the prerequisites for the skills you plan to use (README.md):
       hyperdx    curl, jq  (+ docker for local mode)
       langfuse   curl, python3
       pr-review  gh (run 'gh auth login'), jq

Skills installed to: $SKILLS_DIR
EOF
