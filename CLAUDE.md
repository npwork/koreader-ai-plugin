# koreader-ai-plugin

One person owns and uses this. There is no other user and no release to
coordinate with — the same rules as `ai-small-projects`, applied to a Lua
plugin that ships to one Kindle.

## Git

Commit and push to `main`; no feature branches and no PRs unless the session
is told otherwise. Push when a chunk of work is finished: CI runs on the push,
and a `v*` tag is what publishes a release artifact.

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

There is no emulator in the cloud environment by default; `docs/emulator.md`
says exactly what to change if you need one, and what only the physical Kindle
can answer.

## Changing things

* No backward compatibility. Change the settings shape, the API contract or the
  package layout outright; there is no old client to keep working.
* `plugin/aidict.koplugin/aidict/version.lua` is the single source of the
  version. The package name, the KPM manifest and `version.json` all follow
  from it — never edit a version anywhere else.
* Delete dead code and dead settings rather than keeping them "just in case".
