# Releasing

## The one thing to understand: the version bump is the release

There is no publish step. No workflow to trigger, nothing uploaded anywhere.

`/plugin marketplace add LunarCommand/claude-skills` reads this repository's
**default branch**, so the moment a change lands on `main` it is what new
installs receive. For people who *already* installed a plugin, one field decides
whether they ever see the change:

> A marketplace client offers an update only when the plugin's `version` in
> `plugin/.claude-plugin/plugin.json` changes.

Merge a fix without bumping that field and every existing user keeps running the
old copy indefinitely. Nothing warns them and nothing warns you — which is why
`scripts/validate.sh` fails when anything under `plugin/` changed since the last
tag but the version did not.

**A tag is a bookmark, not a shipment.** It records what shipped and lets users
pin (`/plugin marketplace add https://github.com/LunarCommand/claude-skills.git#v1.2.0`),
but tagging is not what delivers anything.

## Versioning

The repository is one plugin, `lunar`, with one version. A fix to any skill moves
it, and every user gets every skill — there is nothing to install piecemeal and
nothing that can lag behind. Semantic versioning, judged from the consumer's
side:

| Bump | When |
| --- | --- |
| **major** | A user's existing invocations or config stop working: a renamed script, a removed flag, a permission rule that must change. |
| **minor** | New capability, or behaviour that changes but does not break anything already written down. |
| **patch** | A fix with no interface change. |

Prose-only edits to a `SKILL.md` still need a bump. The Markdown *is* the
artifact — a skill is its instructions — so a user running the old text is
running the old skill.

The tag matches the plugin version: `vX.Y.Z` for `lunar` `X.Y.Z`. They were
separate while six plugins shared one repository tag; with one plugin, two
numbers for one thing is a drift waiting to happen.

## Cutting a release

1. **Confirm the version is bumped.** `scripts/validate.sh` compares the
   manifest against the highest `v<number>` tag and requires a *higher* version —
   a repeat, a decrement, a missing field, or a non-`X.Y.Z` string all fail. It
   only asks when `plugin/` changed, since that is exactly what a user
   receives. It compares against the git index, so it sees what a
   commit will contain and ignores unrelated work in progress.

   `SKIP_VERSION_CHECK=1` bypasses the check entirely. It exists for a clone with
   no tags available; using it to get past a genuine un-bumped version ships a
   change nobody will be offered.

2. **Bring `CHANGELOG.md` up to date.** Move `Unreleased` into a new
   `## vX.Y.Z — <date>` section, with one subsection per skill that changed and a
   `### Repository` subsection for anything that belongs to no skill. Write it
   from the user's point of view: what changed for them, not which files moved.
   Refresh it as work lands rather than composing it at tag time.

   This section becomes the Release notes verbatim in step 7, so the changelog
   and the published notes stay identical by construction rather than by
   remembering to copy one into the other.

3. **Sweep the docs for stale wording.** For each behaviour change, grep for the
   old spelling — command names, flags, file paths, prerequisites — across
   `README.md`, `CLAUDE.md`, `docs/`, `install/`, and every `SKILL.md`.
   `validate.sh` catches a `*.sh` name that no longer ships and a `SKILL.md` that
   names a script by path; it cannot catch a stale sentence.

4. **Check the date.** The `CHANGELOG` heading must be the day you actually tag,
   in the **tagger's local timezone** — not UTC. Every release through `v1.0.0`
   uses the local date, and for two of them it differs from UTC: an evening tag
   from a US timezone has already rolled over there, so a reviewer reading
   GitHub's clock reports the heading as a day behind when it is not. Check
   against the tag rather than against a clock — `format:` renders the zone
   recorded in the tag, where `format-local:` would re-render it in whichever
   zone the reader is sitting in and reintroduce the same disagreement:

   ```bash
   git for-each-ref refs/tags/v1.0.0 --format='%(taggerdate:format:%Y-%m-%d %z)'
   ```

   Drift is normal when the entry was drafted early.

5. **Review what is about to ship.** `git diff <last-tag>..main` alongside the new
   CHANGELOG section, read together, before anything is tagged.

6. **Tag and push.**

   ```bash
   git tag -a v1.1.0 -m "v1.1.0"
   git push origin v1.1.0
   ```

7. **Publish the GitHub Release.** A pushed tag does *not* create one — they are
   separate objects, and a repository with tags but no Releases shows an empty
   Releases panel, which reads as a project that does not cut releases. Use the
   CHANGELOG section as the body:

   ```bash
   # strip the heading; the release title carries the version
   awk '/^## v1\.1\.0/{f=1;next} /^## /{f=0} f' CHANGELOG.md > /tmp/notes.md
   gh release create v1.1.0 --title "v1.1.0" --notes-file /tmp/notes.md --latest
   ```

   Nothing in the install path depends on this — the marketplace serves from the
   default branch either way. It exists so people can see what the project is at
   and what changed.

## Verifying a release reached users

The honest check is to install as a stranger would. These are Claude Code
commands, typed in a session — not shell:

```
/plugin marketplace update lunar-skills
/plugin install lunar@lunar-skills
```

Third-party marketplaces have auto-update **off** by default, so an existing user
sees a new version after `/plugin marketplace update`, not automatically.

## Developing against a local clone

A marketplace whose source is a local directory loads the working tree in place,
so a release is irrelevant there: `/reload-plugins` picks up whatever is on disk.
That is the right setup for working *on* this repo and the wrong one for judging
what a user receives — the version field gates them and not you. Verify a release
the way the section above says, from the published marketplace.
