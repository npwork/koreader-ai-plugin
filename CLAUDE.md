# koreader-ai-plugin

One person owns and uses this. There is no other user and no release to
coordinate with — the same rules as `ai-small-projects`, applied to a Lua
plugin that ships to one Kindle.

## Git

Commit and push to `main`; no feature branches and no PRs unless the session
is told otherwise. **A push to `main` is a stable release**: CI publishes it
and the Kindle picks it up on the next `;kpm upgrade`. The `dev` branch feeds
the dev channel the same way.

Versions are not chosen by hand: `major.minor` live in `version.lua`, the patch
is the branch's commit count.

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

Run it, every time, before the push — not after. A push here is a release:
by the time CI goes red the broken package is already on Pages, waiting for
the next `;kpm upgrade` to put it on the Kindle. CI is the second opinion,
never the first.

`make check` covers what runs in a container. Two things it does not:

* `make check-all` adds the real KPM over real HTTP, worth it when the change
  touches packaging, `scripts/` or the manifest.
* Nothing local loads the plugin into KOReader. The `koreader smoke` workflow
  does that on a push, and `docs/emulator.md` says what to change to run one
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
