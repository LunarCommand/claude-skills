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
#   - an existing skill directory is moved to ~/.claude/skill-backups/<stamp>/,
#     OUTSIDE the scanned skills root — see the comment on BACKUP_ROOT below
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

# Backups live OUTSIDE $SKILLS_DIR. Claude Code scans every directory under the
# skills dir for a .claude-plugin/plugin.json and loads each as a plugin named by
# that manifest, so an in-place `<name>.bak-<stamp>` copy is a second directory
# claiming the live plugin's name. One of the pair then loses the name collision
# and the other is served — which is not reliably the fresh install. That put a
# stale SKILL.md, a stale bin/ on PATH, and a stale workflow engine in front of
# the user after a routine re-install. Before the manifests existed a backup was
# inert, which is why this was safe until it wasn't.
stamp="$(date +%Y%m%d%H%M%S)"
BACKUP_ROOT="$CLAUDE_DIR/skill-backups/$stamp"
# Two runs inside the same second would otherwise share a directory, and
# `mv a b` with b an existing directory nests it as b/a rather than replacing.
suffix=1
while [[ -e "$BACKUP_ROOT" ]]; do
  BACKUP_ROOT="$CLAUDE_DIR/skill-backups/$stamp-$suffix"
  suffix=$((suffix + 1))
done

echo "Installing Claude Skills Toolkit into $SKILLS_DIR"
mkdir -p "$SKILLS_DIR"

# Every directory under skills/ installs as ~/.claude/skills/<name>/.
for src in "$REPO_DIR"/skills/*/; do
  name="$(basename "$src")"
  dest="$SKILLS_DIR/$name"
  if [[ -e "$dest" ]]; then
    mkdir -p "$BACKUP_ROOT"
    echo "  ~ backing up existing $name -> skill-backups/$(basename "$BACKUP_ROOT")/$name"
    mv "$dest" "$BACKUP_ROOT/$name"
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

  2. Approve the skill scripts, or every call prompts. They are on the Bash
     tool's PATH, so the rules name them directly:

       Bash(adversarial_review_path.sh:*)   Bash(pr_review_parse_comments.sh:*)
       Bash(hdx_query.sh:*)                 Bash(pr_review_post_reply.sh:*)
       Bash(langfuse_query.sh:*)            Bash(pr_review_resolve_thread.sh:*)

     Those six are safe in ~/.claude/settings.json. The FULL template at
       $REPO_DIR/project-files/.claude/settings.json
     is a project config — it also sets defaultMode auto and grants Write,
     Edit, Agent, WebFetch and more, so use it whole only inside a project you
     trust, never at user scope. See README.md.

  3. Check the prerequisites for the skills you plan to use (README.md):
       hyperdx    jq, plus curl (cloud mode) or docker (local mode)
       langfuse   curl, python3
       pr-review  gh (run 'gh auth login') — no jq, gh has its own

Skills installed to: $SKILLS_DIR
EOF
