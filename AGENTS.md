# koreader-ai-plugin

One person owns and uses this. There is no other user and no release to
coordinate with — the same rules as `ai-small-projects`, applied to a Lua
plugin that ships to one Kindle.

## Definition of done

For an implementation task, carry the work through implementation, relevant
validation, a pull request, completed code review, review fixes, a squash merge
to `main`, and deployment through the existing production release process.
Finish with a practical production check when it is straightforward and the
required access is available. Follow explicit user limits, such as a request
for a plan, draft, or changes without deployment.

The owner authorizes this complete workflow for requested work in this
repository: push relevant changes to its existing GitHub `origin`, create the
PR, address review, merge, and deploy after the required checks pass. Continue
without asking for confirmation at each routine step. Platform approval
requirements still apply; these instructions do not change those controls.

Report what shipped, the PR, validation performed, and any material limitation.
If review, CI, or deployment is blocked, keep working on the blocker and report
anything that remains unresolved. For non-shipping changes, completion means
publishing them through the documentation-only path below; no production
redeployment is needed.

## Git

### Commit messages and merges

- Use Conventional Commits for commit subjects and PR titles:
  `type(scope): summary`, with an optional scope. Use `feat`, `fix`, `docs`,
  `refactor`, `test`, `chore`, `build`, `ci`, `perf`, or `revert` as appropriate.
  Examples: `feat(sync): upload diagnostics` and `fix(sync): retry failed uploads`.
- Mark breaking changes with `!` after the type/scope or a `BREAKING CHANGE:` footer.
- Always squash-merge pull requests into `main`, using the PR title as the
  squash commit title. Keep that title in Conventional Commits format so each
  PR produces one clear commit in the main history.
- The existing required leading `skip ci` control prefix is the only formatting
  exception: follow it with the conventional subject, for example
  `skip ci docs: clarify repository guidelines`. Use it only for the non-shipping
  changes allowed below.

A code merge to `main` publishes a stable release through Pages; the Kindle
installs it through Sync or `;kpm upgrade`. The `dev` branch feeds the dev
channel. Pushing a feature branch releases nothing.

### Delivery workflow

The whole loop is the agent's work, including fixing failed checks and shipping:

1. **Implement on a branch.** Start from current `origin/main`, using
   `claude/<short-name>`, and complete the requested change.
2. **Validate locally.** Run the checks required below for the affected code.
   Fix failures before pushing or opening the PR.
3. **Push and open the PR.** Describe the resulting behavior and validation.
   A branch or open PR is an intermediate step, not task completion.
4. **Wait for code review to finish.** The required `Review` workflow must
   post its completed "AI review" summary and inline findings. Green CI, a
   running review, or a missing in-progress indicator does not establish that
   review finished. If the workflow fails, times out, or reports an incomplete
   review, dispatch `review.yml` once with the PR number and wait again. If it
   fails again, leave the PR unmerged and report the blocker.
5. **Address every review finding.** Reproduce or trace reported bugs, fix all
   confirmed issues, and add relevant regression coverage where useful. Reply
   on each finding's own thread with the fix or a reasoned explanation when it
   is incorrect or cannot be confirmed. Resolve threads after addressing them;
   never silently ignore a comment or change code merely to satisfy a claim
   the evidence does not support.
6. **Validate fixes and squash-merge.** Push the fixes together after rerunning
   the affected local checks. Wait for required CI and smoke checks to pass on
   the exact commit being merged, with review findings handled. No second
   review round is required for those fixes unless explicitly requested or
   required by repository protection. Squash-merge using the PR title as the
   commit title; no additional user confirmation is needed.
7. **Deploy.** Follow the existing release process and confirm the deployment
   completed. A merge, queued workflow, or built image alone does not establish
   that the intended version reached production. Investigate failed or skipped
   deployment rather than leaving the change unshipped.
8. **Check production when practical.** Use the lightweight verification in
   Shipping below. If a check exposes a regression, investigate and fix it
   through this workflow before reporting the task complete. If a useful check
   is unavailable without substantial setup, report that limitation clearly.

The required reviewer is `.github/workflows/review.yml`, running Claude Code on
Nick's subscription and posting as `github-actions[bot]`. An 👀 reaction means
review is in progress; its absence does not replace the completed summary.
Greptile is optional: address its findings when it posts, but do not wait for
it. If its credits are exhausted, ignore it until they return.

### Git ground rules

- Never merge with failing required checks or bypass them to ship a change.
- One PR per completed chunk of work, rather than one per commit.
- If `main` advances, rebase onto current `origin/main`, preserve others' work,
  rerun the affected checks, and wait for CI on the resulting commit.
- Merged branches do not need cleanup; do not spend time deleting them.

### Documentation-only changes

Every change goes through a PR unless the user explicitly requests a direct
commit. For changes that neither execute nor ship, such as docs and text
outside `plugin/`, use a title such as
`skip ci docs: clarify repository guidelines`. The leading `skip ci` control
prefix skips CI, smoke, Review, and Pages publication for the PR and its merge.
For this exception, check the diff and affected references, then squash-merge
without waiting for runtime checks or an automated review. Use the PR title
as the squash commit title so the prefix remains effective.

Do not use this exception for source, executable configuration, workflows,
packaging, or Markdown used as executable reviewer prompts. Documentation
accompanying code belongs in the code PR and follows its full checks. A leading
`skip ci` is case-insensitive; anywhere else it has no effect.

Versions are not chosen by hand: `major.minor` live in `version.lua`; the patch
is the branch's commit count, so each squash-merged PR is one patch release.

## Shipping

For verification, choose the smallest useful check that existing access makes
straightforward: exercise the changed endpoint with a request, use an existing
smoke test, inspect relevant production logs for the operation, or check the
published version and release artifact. A health response establishes
availability; check the changed behavior too when that is easy. Avoid building
new infrastructure, arranging complicated access, or running expensive end-to-end
work merely to obtain a production check. If verification is impractical,
state what was verified and what remains unverified.

After a plugin release, check the stable Pages manifest and package version.
The existing live-repository install/KOReader verification is useful evidence;
verify its result when available. Installing on the physical Kindle requires
the owner's device, so report that limit without blocking publication on
unavailable device access. Documentation-only PRs do not publish a package.

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

For runtime changes, run it before opening the PR and before every push to it.
Documentation-only changes follow their exception above. The merge is a release:
once a broken package is on Pages, the next `;kpm upgrade` puts it on the Kindle.
CI is the second opinion, never the first.

`make check` covers what runs in a container. Two things it does not:

* `make check-all` adds the real KPM over real HTTP, worth it when the change
  touches packaging, `scripts/` or the manifest.
* Nothing local loads the plugin into KOReader. The `koreader smoke` workflow
  does that on the PR, and `docs/emulator.md` says what to change to run one
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

## Comments

By default, write none. Names, tests and the README say what code does; a
comment is only for what they cannot:

* **Why, when it is not obvious**: a KOReader or Kindle quirk, a limit
  outside the code, a choice that looks wrong but is not, a trap the next
  edit would fall into.
* **A contract the signature does not show**: units, ownership, an invariant
  a caller must keep.

Keep it to one line where you can, three at most. Never restate the code,
tell history ("used to", "since 0.2.70"), repeat the README or this file, or
leave commented-out code or banner comments. When a change makes a comment
wrong or pointless, fix or delete it in the same change. The `Review`
workflow flags added comments that break these rules.
