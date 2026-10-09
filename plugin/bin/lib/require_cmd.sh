# shellcheck shell=bash
# Shared dependency preflight for the bundled scripts that shell out.
#
# Without it a missing binary surfaces partway through a pipeline as
# `jq: command not found`, which reads as a bug in the calling script. Every
# SKILL.md tells the agent a failing script must be fixed rather than worked
# around, so an unclear failure sends it editing working code instead of naming
# the real problem.
#
# Exit 127 is the contract -- the shell's own "command not found" status, and
# what CLAUDE.md and the skills document.
#
# Callers source this by explicit path because `bin/lib/` is not a PATH entry.
# `source` DOES search PATH for a slashless name, so a bare `. require_cmd.sh`
# would resolve if this file sat in `bin/` itself -- and it deliberately does
# not, because a file there is a callable command: it would need an executable
# bit and a permission rule, neither of which a sourced fragment should carry.
#
# The bare-name rule is unaffected either way. It governs how a *command* is
# invoked, because the permission allowlist matches a command name, and sourcing
# is not the command a user approves.
#
# The mutation_test_ scripts deliberately do NOT source this. They route the
# same condition through their own `refuse()` to exit 41 with a
# `missing-dependency` slug, which their acceptance suite asserts by identity.
# Two contracts, on purpose; unifying them would change a documented exit code.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Missing required command: $1" >&2
  echo "  $2" >&2
  exit 127
}
