# koreader-ai-plugin

KOReader plugin: tap a word (or hold a selection) and an **AI** button sends the
word, the sentence and the paragraph around it to a remote gateway; the reply —
a definition of the sense this passage gives the word, three examples in that
same sense, and a Russian translation that is fetched but not yet shown — is
displayed in the viewer and cached on the device for thirty days. Shipped to a
Kindle as a KPM package; the gateway's address and key are baked in at build
time and are not in this repository.

## Layout

```
plugin/aidict.koplugin/   the plugin as it lands on the device
  main.lua                the only file that requires KOReader modules: buttons, menu, widgets
  aidict/                 plain Lua, no KOReader imports, dependencies passed as arguments
    apiclient.lua         request/response/error mapping
    cache.lua             LRU + TTL cache
    config.lua            defaults and validation
    context.lua           UTF-8 text window around the word
    format.lua            result -> displayed text
    http_transport.lua    the one file that uses luasocket
    json.lua              rapidjson if present, else KOReader's json
    lookup.lua            settings + cache + client wired together
    prefetch.lua          whether to look a word up before the reader asks
    reqid.lua             one id per lookup, so both sides log under the same one
    settings.lua          typed access over a LuaSettings-shaped store
    updater.lua           "is there a newer build on my channel?"
    version.lua           major.minor; patch = branch commit count, set at build
spec/                     busted suite, runs under plain lua5.1 (support/ holds stubs and a fake gateway)
packaging/                install.sh / uninstall.sh, KPM hooks
scripts/                  package/repo builder, verification and emulator helpers
docs/                     api.md (gateway contract), testing.md, emulator.md, distribution.md
```

## Rules

* Behaviour goes in `aidict/` with a test in `spec/`; widgets go in `main.lua`.
  Logic that is hard to test is on the wrong side of that line.
* Versions are never written by hand outside `version.lua`.
* No backward compatibility: change settings, API contract or package layout outright.
* Delete dead code and dead settings.

## Check before pushing

```bash
make check      # luacheck + busted + package install/upgrade/uninstall in a temp tree
```

Needs `lua5.1`, `luarocks`, and `busted dkjson luacheck luasocket`. No display,
no KOReader checkout, no Kindle.

## Gateway

`POST <endpoint>/define` with `{word, context, sentence}`, answered with
`{definition, examples}`. Full contract in `api.md`. The endpoint is not stored
in this repository; `config.lua` ships it empty and it is set at build time or
from the plugin's menu. The bearer token is typed on the device only.
