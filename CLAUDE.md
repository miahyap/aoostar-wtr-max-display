# aoostar-wtr-max-display — guidance for Claude

## Fixing bugs — always add a regression test

When you debug and fix a behavioural bug (not a trivial typo), **add a check
that fails before the fix and passes after it**, in the same change. The test
is what stops the bug from silently coming back — a fix without one is only
half done.

### How to do it

1. **Reproduce first.** Before writing the fix, confirm you can make the bug
   observable. If you proved the root cause with a throwaway experiment (e.g.
   parsing the plg in a `php` container, running the collector against mock
   `disks.ini`/`sysinfo.txt` data in a `bash` container), fold that proof into
   a repeatable check rather than deleting it.
2. **Pin the actual failure mode, not just a constant.** Test the behaviour
   that broke. If the bug was format-driven (plugin-manager `<INLINE>`
   semantics, asterctl's accumulate-only sensor map, inherited fds keeping a
   web request open), assert the property that makes the behaviour correct.
3. **Use the layers this repo already has.** `src/build.py` refuses invalid
   payloads; the plg simulator (XML parse + SHA256 + base64 round-trip),
   `bash -n` on every script, `xmllint --noent`, and Docker containers
   (`bash:5.2` for collector behaviour, `php:8.2-cli`/`php:7.4-cli` for the
   exact Unraid parse) all run on the Mac with no hardware. Only on-display
   layout needs the real device.
4. **Make the invariant testable.** If the buggy value was inline, lift it
   into a named constant or function (in `build.py`/`make_panel.py`/the shell
   scripts) so a check can assert on it and the call site stays the single
   source of truth.
5. **Explain the bug in the check.** A short comment naming the original
   symptom ("two temperature colors overlapping") and why the assertion guards
   it is worth more than the assertion alone.

## Panel and plugin artifacts — generated, single source of truth

Everything the plugin ships is **generated** — never hand-edit build outputs.

- `unraid-plugin/aoostar-lcd.plg` is built by `src/build.py` (bump `VERSION`
  there for every user-visible change).
- `src/plugin-root/panel/monitor.json` and `panel/unraid-dark.png` are built
  by `src/make_panel.py` — layout constants (zones, palette) live there once
  and are shared by the background and the sensor coordinates. Change the
  panel by editing `make_panel.py` and regenerating, not by editing the JSON.
- The icon comes from `src/make_icon.py`.
- New colours/positions belong in the named constants (palette, zone tuples)
  at the top of `make_panel.py`, not as literals sprinkled into sensor
  definitions.
- The `<PLUGIN>` tag's `pluginURL` and `support` attributes come from
  `PLUGIN_URL` / `SUPPORT_URL` in `build.py`. `support` must point at this
  repo's issues — never at upstream aoostar-rs, or plugin bug reports land on
  the driver author's board. `pluginURL` is what Unraid's Plugins page uses to
  self-update an installed plugin, so it must stay a valid raw URL to the
  committed plg.
- Dynamic color = triple label slots (`_g`/`_a`/`_r`) written by
  `unraid-stats.sh`. Every label must be rewritten every cycle (empty value =
  render nothing): asterctl's sensor map never drops absent keys, so relying
  on key absence causes stale overlaps.

Rebuild + validate after any source change:
`python3 src/make_panel.py && python3 src/build.py && xmllint --noent --noout
aoostar-lcd.plg` plus `bash -n` on changed scripts.

## Git commits — split by logical concern

When the user asks you to commit and the working tree contains multiple
independent changes, **split them into a sequence of focused commits** rather
than landing one big commit. The PR still squash-merges to a single commit on
`main` (the repo enforces squash-only), but during review the individual
commits make the story easy to follow and let you revert one piece without
losing the others.

### When to split

Split into separate commits when the changes:

- Touch unrelated concerns (e.g. a collector bugfix + an unrelated settings-page field).
- Could be reverted independently and still leave the tree in a coherent state.
- Belong to different phases of a larger task (e.g. "add helper" → "use helper" → "remove old code").
- Mix refactor with behavioural change. A pure rename or move should land in its own commit before the change that depends on the new shape.

### When NOT to split

Keep changes together when:

- They are tightly coupled and splitting them would leave the tree broken
  between commits. Example: a `make_panel.py` label change and the
  `unraid-stats.sh` code that writes that label must land together — and the
  regenerated plg belongs in the same commit as the source that produced it.
- One of the pieces is just incidental noise (a typo fix you noticed while
  editing the same file). Roll it into the main commit and mention it in the body.
- The user already asked for a single commit explicitly.

### How to do it

1. Run `git status` and `git diff` to see what's staged and unstaged.
2. Identify the logical groups. Name them out loud before staging.
3. Stage explicit paths per commit — never `git add -A` or `git add .`. Use `git add -p` if a single file contains multiple unrelated hunks.
4. Verify each commit leaves the repo in a working state: the rebuild +
   validate pipeline above should pass after every commit, not just the last
   one, and the committed plg must match its sources.
5. Write a focused subject + body for each commit. The body explains *why*,
   not what (the diff shows what).

---

When in doubt, ask the user how they want it grouped before committing.

## Opening a PR — check the docs first

**Before opening any PR, check whether the change makes existing documentation
stale, and update it in the same PR.** Code and docs drift apart one un-updated
PR at a time; the cheapest moment to fix a doc is while the change that
invalidated it is still in your head.

### How to do it

1. **Diff against the docs.** Look at what the PR actually changed — settings
   keys, panel contents, rc-script commands, file locations, install steps —
   and grep the docs (`README.md`, `unraid-plugin/README.md`, the settings
   page's Notes section in `AOOSTARLCD.page`, `CLAUDE.md`) for anything that
   describes those things.
2. **Fix what drifted.** If a settings field was added, the page defaults, the
   `install.sh` cfg template, the rc defaults, and the README must all agree.
   The settings tables, feature lists, and install steps go stale fastest.
3. **Fold it into the PR.** Documentation updates ride along in the same PR as
   the change that motivated them — as their own focused commit per the rules
   above, not a separate follow-up PR.
4. **Nothing to change is a valid answer** — but only after you've looked.
   Don't assume a change is doc-neutral; confirm it.

## Merging PRs — main requires a review, and bypassing it is the user's call

`main` is protected: **1 approving review required**, squash-only merges. There
are no required status checks. GitHub does not let a PR author approve their own
PR, so on this effectively-solo repo `gh pr merge` will fail with *"the base
branch policy prohibits the merge"* and `reviewDecision: REVIEW_REQUIRED` —
this is the normal state of a fresh PR here, not a misconfiguration to fix.

`enforce_admins` is **off**, so the owner can override the requirement with
`gh pr merge <n> --squash --admin`. That works, and for a docs-only change it is
often the right answer.

### How to do it

1. **Never pass `--admin` on your own initiative.** Bypassing a protection rule
   the user deliberately set up is their decision, every time. Asking once does
   not create standing permission for the next PR.
2. **Surface the options rather than picking one**: admin-bypass now, `--auto`
   to merge whenever an approval arrives, or relax
   `required_approving_review_count` if the rule is a permanent obstacle rather
   than a one-off. Say plainly that the rule as configured can never be
   satisfied by a solo author, so it recurs on every PR.
3. **A declined merge leaves the PR open, and that is a fine outcome.** Don't
   retry with escalating force or look for another route to land it.
4. **Check the real config before describing it** —
   `gh api repos/<owner>/<repo>/branches/main/protection` — instead of repeating
   the summary above, which goes stale if the rules change.

## Dependencies — only pin versions that have aged at least a week

**When adding or updating any pinned third-party artifact, the version you pin
must have been published at least one week ago.** A freshly released version is
the prime window for a compromised or broken release to slip in before the
ecosystem notices.

### How to do it

1. This repo's main dependency is the **asterctl release tarball**
   (`unraid-plugin/asterctl-*.tar.gz`, sha256 recorded in
   `unraid-plugin/README.md`). Before bumping it, check the release's publish
   date on <https://github.com/zehnm/aoostar-rs/releases> (or
   `gh api repos/zehnm/aoostar-rs/releases`) and confirm it is ≥ 7 days old.
   Note the `latest` tag is a moving dev build — its assets get replaced, so
   always verify the checksum of the copy you commit.
2. **There is no automatic enforcement here** (no pnpm equivalent), so the
   check is manual — do it every time, and record the new sha256 in the README
   alongside the bump.
3. **Applies to anything else pinned** — Docker image tags used in test
   commands, any future vendored tool.
4. **If the user explicitly asks for a too-new version**, surface that it
   breaches the 1-week rule and confirm before proceeding.
