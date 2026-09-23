# koreader-ai-plugin

KOReader plugin: tap a word (or hold a selection) and an **AI** button sends
the word, the sentence and the paragraph around it to a remote gateway. The
answer is a dictionary entry for the sense *this passage* gives the word —
headword, IPA, part of speech, a definition, three examples in that same sense
with the word marked in each, and a line of etymology. A Russian translation
is fetched and cached but not yet shown. Everything is cached on the device
for thirty days.

The request does not wait for the button. It goes out when the dictionary
opens, so by the time **AI** is pressed the answer is usually already there;
pressing it while the request is still out joins that one rather than starting
a second. This is on by default and switched off in the menu — it costs a
request per dictionary lookup rather than per AI press.

The same plugin also carries the **book library**: *Sync library* in the menu
asks the gateway what is in the owner's R2 bucket and downloads whatever this
Kindle does not have, mirroring the bucket's folders under `/mnt/us/AI_Books`.
Nothing syncs on its own — it is a button, pressed when wanted, or a gesture
if one is bound to it. The plugin has one entry in the menu, **AI dictionary**,
first in the **Tools** tab; the sync is the first line inside it and the update
the second, above the settings — the two things that get pressed, two taps
from the page.

Shipped to a Kindle as a KPM package; the addresses are baked in at build time
and are not in this repository, and the key is typed in on the device.

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
    kpm.lua               driving the Kindle package manager to update this package
    library.lua           the book sync: manifest, plan, download
    lookup.lua            settings + cache + client wired together
    manifest.lua          the library manifest, and which paths may be written
    plan.lua              manifest vs what is on the device -> what to download
    prefetch.lua          whether to look a word up before the reader asks
    reqid.lua             one id per lookup, so both sides log under the same one
    settings.lua          typed access over a LuaSettings-shaped store
    updater.lua           "is there a newer build on my channel?"
    version.lua           major.minor; patch = branch commit count, set at build
    vocab.lua             the Kindle's own vocab.db, sent to the word inbox since the last upload
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

## Updating itself

**Update the plugin** — second in AI dictionary, under the sync — asks the
channel's `version.json` whether there is something newer, and offers to
install it. Installing runs the Kindle's own
package manager — `kpm -y install koreader-aidict`, found at
`/var/local/kmc/<platform>/bin/kpm` — from inside KOReader, so an update does
not mean leaving the book to type `;kpm install …` into the Kindle's search
bar. `install` rather than `upgrade`: KPM's `upgrade` walks every package the
reader has, and a button here has no business updating somebody else's.

KPM replaces the plugin underneath a running KOReader, which is safe — the Lua
already loaded stays loaded — so the restart that picks up the new code is
offered, not taken.

## Check before pushing

```bash
make check      # luacheck + busted + package install/upgrade/uninstall in a temp tree
```

Needs `lua5.1`, `luarocks`, and `busted dkjson luacheck luasocket`. No display,
no KOReader checkout, no Kindle.

## Gateway

`POST <endpoint>/define` with `{word, context, sentence}`, answered with
`{lemma, pronunciation, definition, etymology, examples, forms, …}`. Full
contract in `api.md`. Neither the endpoint nor the key is stored in this
repository. `config.lua` ships both empty; the build injects the address from
the `AIDICT_ENDPOINT` secret, and the key is never injected at all — the
published package is world-readable and the gateway's key now opens the codex
proxy and the Words data endpoint too, so it is typed once into the plugin's
own "API key" field on the device.

The library lives on the gateway, at `GET <library endpoint>/manifest`, and its
address comes only from the `AIDICT_LIBRARY_ENDPOINT` secret, baked into the
package at build time. It is not a setting: the plugin's menu shows it on the
"Library" line and cannot change it. A new address reaches the device the way
a new version does — change the secret, rebuild Pages, `;kpm upgrade`.

It used to be derived from the dictionary's by swapping the last path segment,
which held while both mounts sat on the same gateway. `/koreader-ai` moved to a
Cloudflare Worker on 2026-09-22 and the library stayed with the books, so the
two addresses have nothing to do with each other. The dictionary's is still a
setting the reader can change; the library's is not.
