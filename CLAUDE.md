# koreader-ai-plugin

One person owns and uses this. There is no other user and no release to
coordinate with — the same rules as `ai-small-projects`, applied to a Lua
plugin that ships to one Kindle.

## Git

Every change lands on `main` through a reviewed pull request, the same loop as
`ai-small-projects`. **A merge to `main` is a stable release**: Pages publishes
it and the Kindle picks it up on the next `;kpm upgrade`. The `dev` branch
feeds the dev channel the same way.

The whole loop is the agent's work, not Nick's:

1. **Branch.** Off current `origin/main`, named `claude/<short-name>`. Commit
   there. A pushed branch releases nothing: Pages runs only for `main` and
   `dev`.
2. **Test, then open.** `make check` (see below). Red means do not open the PR.
3. **Push the branch and open the PR.** `ci` runs on it, and `koreader smoke`
   too when `plugin/` changed, so a broken plugin is visible before it is a
   release.
4. **Wait for the reviews.** Whatever reviewer is connected to this repository
   posts on its own a few minutes after the push. If it says its free credits
   for the month are spent, or none shows up at all, that is not a blocker:
   say so in the thread and go on to the merge.
5. **Answer every comment, in one round.** Fix the ones you agree with **and
   can confirm**: reproduced, or traced to the line that proves it. A comment
   you disagree with, or cannot confirm from the code, gets a reply on its own
   thread saying why the code stays as it is. Resolve each thread you
   answered. Never leave one silently unanswered, and never edit code to
   satisfy a comment you do not believe.
6. **Push the fixes and merge.** No second round of review. Once CI and the
   smoke test are green on the commit you are merging, squash-merge into
   `main`. That merge is the release; Nick does not press the button.

- Red CI is work, now. Never merge red.
- Committing straight to `main` is for when Nick asks for it, and nothing else.
- One PR per chunk of work, opened when the chunk is finished.
- Merged branches are not worth cleaning up; a cloud session cannot delete
  them anyway.
- `main` moves under you. Rebase onto the new `origin/main`, run `make check`
  again, and never revert someone else's change to land your own.

Versions are not chosen by hand: `major.minor` live in `version.lua`, the patch
is the branch's commit count, so each squash-merged PR is one patch release.

## The layering rule

`plugin/aidict.koplugin/main.lua` is the only file allowed to `require` a
KOReader module. Everything under `aidict/` takes what it needs as an
argument — a transport function, a JSON codec, a clock, a settings store —
and is covered by `spec/`.

When a change needs new behaviour, it goes in `aidict/` with a test. When it
needs a new widget, it goes in `main.lua`. If a piece of logic is hard to test,
that is the layering telling you it is on the wrong side.

## Before pushing

```bash
make check      # luacheck + busted + package install/upgrade/uninstall
```

Run it, every time, before opening the PR and before every push to it. The
merge is a release: once a broken package is on Pages, the next `;kpm upgrade`
puts it on the Kindle. CI is the second opinion, never the first.

`make check` covers what runs in a container. Two things it does not:

* `make check-all` adds the real KPM over real HTTP, worth it when the change
  touches packaging, `scripts/` or the manifest.
* Nothing local loads the plugin into KOReader. The `koreader smoke` workflow
  does that on the PR's push, and `docs/emulator.md` says what to change to run one
  here — and what only the physical Kindle can answer.

Unlike `ai-small-projects`, this repo is public, so its Actions minutes are
free and its CI runs in full. Do not turn any of it off to save minutes;
there are none to save.

## Changing things

* No backward compatibility. Change the settings shape, the API contract or the
  package layout outright; there is no old client to keep working.
* `plugin/aidict.koplugin/aidict/version.lua` holds `major.minor`; the patch is
  the branch's commit count, filled in at build time. Never write a version
  anywhere else.
* Delete dead code and dead settings rather than keeping them "just in case".
