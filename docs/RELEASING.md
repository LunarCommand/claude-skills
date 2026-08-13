# Releasing

## The one thing to understand: the version bump is the release

There is no publish step. No workflow to trigger, nothing uploaded anywhere.

`/plugin marketplace add LunarCommand/claude-skills` reads this repository's
**default branch**, so the moment a change lands on `main` it is what new
installs receive. For people who *already* installed a plugin, one field decides
whether they ever see the change:

> A marketplace client offers an update only when the plugin's `version` in
> `.claude-plugin/plugin.json` changes.

Merge a fix without bumping that field and every existing user keeps running the
old copy indefinitely. Nothing warns them and nothing warns you — which is why
`scripts/validate.sh` fails when a skill's files changed since the last tag but
its version did not.

**A tag is a bookmark, not a shipment.** It records what shipped and lets users
pin (`/plugin marketplace add https://github.com/LunarCommand/claude-skills.git#v1.2.0`),
but tagging is not what delivers anything.

## Versioning

Each skill is its own plugin with its own version, so they move independently — a
langfuse fix does not drag hyperdx along. Semantic versioning, judged from the
consumer's side:

| Bump | When |
| --- | --- |
| **major** | A user's existing invocations or config stop working: a renamed script, a removed flag, a permission rule that must change. |
| **minor** | New capability, or behaviour that changes but does not break anything already written down. |
| **patch** | A fix with no interface change. |

Prose-only edits to a `SKILL.md` still need a bump. The Markdown *is* the
artifact — a skill is its instructions — so a user running the old text is
running the old skill.

The repository tag is separate: `vX.Y.Z` marks the release event across all
plugins. It does not have to match any plugin's version, and usually will not.

## Cutting a release

1. **Confirm every changed plugin is bumped.** `scripts/validate.sh` does this
   against the last `v*` tag. Do not reach for `SKIP_VERSION_CHECK=1` to get past
   it — that variable exists for working in a shallow clone, not for skipping the
   bump.

2. **Bring `CHANGELOG.md` up to date.** Move `Unreleased` into a new
   `## vX.Y.Z — <date>` section, keeping one subsection per plugin that changed
   with the version it ships as. Write it from the user's point of view: what
   changed for them, not which files moved. Refresh it as work lands rather than
   composing it at tag time.

3. **Sweep the docs for stale wording.** For each behaviour change, grep for the
   old spelling — command names, flags, file paths, prerequisites — across
   `README.md`, `CLAUDE.md`, `docs/`, `install.sh` output, and every `SKILL.md`.
   `validate.sh` catches a `*.sh` name that no longer ships and a `SKILL.md` that
   names a script by path; it cannot catch a stale sentence.

4. **Check the date.** The `CHANGELOG` heading must be the day you actually tag.
   Drift is normal when the entry was drafted early.

5. **Review what is about to ship.** `git diff <last-tag>..main` alongside the new
   CHANGELOG section, read together, before anything is tagged.

6. **Tag and push.**

   ```bash
   git tag -a v1.1.0 -m "v1.1.0"
   git push origin v1.1.0
   ```

   Optionally publish a GitHub Release using the CHANGELOG section as its body.
   Nothing depends on it.

## Verifying a release reached users

The honest check is to install as a stranger would:

```bash
/plugin marketplace update lunar-skills
/plugin install hyperdx@lunar-skills
```

Third-party marketplaces have auto-update **off** by default, so an existing user
sees a new version after `/plugin marketplace update`, not automatically.

## The clone route

`install.sh` users get changes by pulling and re-running it — version fields do
not gate that path. It is worth remembering that the two routes drift for a
different reason: a clone tracks whatever `main` currently is, while a plugin
install tracks the last version bump.
