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
# Callers source this by PATH-relative path, which looks like it contravenes the
# bare-name rule and does not: that rule governs how a *command* is invoked,
# because the permission allowlist matches a command name. `source` does not
# search PATH at all, so there is no bare-name spelling available here, and this
# path never appears in a command a user approves. `bin/` is the one directory
# Claude Code puts on PATH; `bin/lib/` is not a PATH entry, so nothing in here
# is reachable by name and nothing in here needs a permission rule.
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
