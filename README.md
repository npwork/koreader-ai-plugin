# koreader-ai-plugin

A KOReader plugin that explains the word you tapped — in the sentence you
tapped it in — by asking a remote AI service, plus the KPM repository that
installs and updates it over Wi-Fi.

Nothing in this repository needs a Kindle or a laptop: the plugin is built and
tested in a plain Linux container, packaged there, and the Kindle pulls it down
with `kpm`.

## What it does

Tap a word in KOReader and the dictionary popup gets an **AI** button; hold a
selection and the highlight menu gets **Explain with AI**. Either one sends the
word plus the surrounding sentence to a gateway endpoint and shows what comes
back: a definition, a translation, examples.

Answers are cached on the device, so re-tapping a word you already looked up
costs nothing and works offline.

## Layout

```
plugin/aidict.koplugin/      the plugin, exactly as it lands on the device
  main.lua                   KOReader glue: buttons, menu, widgets, events
  _meta.lua
  aidict/                    everything else — plain Lua, no KOReader imports
    apiclient.lua            builds the request, reads the response, maps errors
    cache.lua                LRU + TTL cache, serialisable
    config.lua               defaults and validation rules
    context.lua              UTF-8 text windowing around the selected word
    format.lua               result -> the text shown in the viewer
    http_transport.lua       the one file that speaks luasocket
    json.lua                 rapidjson if present, KOReader's json otherwise
    lookup.lua               settings + cache + client, wired together
    settings.lua             typed access over any LuaSettings-shaped store
    updater.lua              "is there a newer build on my channel?"
    version.lua              the single source of the version number
spec/                        busted suite (119 tests, no KOReader needed)
packaging/                   install.sh / uninstall.sh, the KPM hooks
scripts/kpmrepo.py           builds the .kpkg and the KPM repository
scripts/verify-package.sh    installs, upgrades and uninstalls into a temp tree
```

The split is deliberate: `main.lua` holds every KOReader-specific line, and
everything under `aidict/` takes its dependencies as arguments — a transport
function, a JSON codec, a clock, a settings store. That is what makes the suite
run under plain `lua5.1` with no emulator.

## Development

```bash
sudo apt-get install -y lua5.1 liblua5.1-0-dev luarocks
sudo luarocks install busted dkjson luacheck

make test      # busted
make lint      # luacheck
make verify    # build the .kpkg, install/upgrade/uninstall it in a temp tree
make check     # all three
```

`make check` is what CI runs. It needs no network, no display and no KOReader
checkout.

For running the plugin inside the KOReader emulator, see
[docs/emulator.md](docs/emulator.md) — it works, but the cloud environment
needs two network settings changed first, and the document says exactly which.

## Packaging and publishing

```bash
make package                      # dist/koreader-aidict_<version>_kindleany.kpkg
make repo CHANNEL=stable          # dist/repo/stable/{manifest.json,version.json,SHA256SUMS,packages/…}
make repo CHANNEL=dev
```

`dist/repo/<channel>/` is a complete KPM repository, ready to be served as
static files:

* `manifest.json` — what KPM reads. Artifact URLs are relative to the manifest,
  so the tree can be moved anywhere without editing it.
* `version.json` — what the plugin's own update check reads: the newest version
  per package, its absolute URL and its sha256.
* `SHA256SUMS` — checksums for every artifact in the channel.

Bumping the version means editing `plugin/aidict.koplugin/aidict/version.lua`;
the package name, the KPM manifest and `version.json` all follow from it.

Publishing it on the DigitalOcean box is the next piece of work — see
[docs/distribution.md](docs/distribution.md) for the plan and the URLs it
assumes.

## Installing on the Kindle

Once the repository is served (the URLs below are the intended ones), from the
Kindle search bar:

```
;kpm repo add https://repo.example/kpm/stable/manifest.json
;kpm install koreader-aidict
```

and to update later:

```
;kpm update
;kpm upgrade koreader-aidict
```

Restart KOReader after either. No USB, no computer.

`install.sh` copies the plugin into `/mnt/us/koreader/plugins/aidict.koplugin`,
replacing whatever was there; `uninstall.sh` removes it and leaves your
settings alone.

## Settings

KOReader menu → **AI dictionary**:

| Setting | Default | What it does |
| --- | --- | --- |
| Endpoint | `https://gateway.example/koreader-ai` | The gateway. The plugin POSTs to `<endpoint>/define`. |
| API key | empty | Sent as `Authorization: Bearer …` when set. |
| Answer language | `ru` | Language the explanation is written in. |
| Context sent | 320 characters | How much of the surrounding sentence goes with the word. 0 sends the word alone. |
| Cache | 200 answers, 30 days | Cleared from the same menu. |
| Update channel | `stable` | `stable` or `dev`. |

They live in `koreader/settings/aidict.lua` on the device.

## The API it expects

See [docs/api.md](docs/api.md). In one line: `POST <endpoint>/define` with
`{"word": …, "context": …, "target_lang": …}`, answered with
`{"definition": …, "translation": …, "examples": [...]}`.

The gateway side of that contract lives in `ai-small-projects` and is not built
yet.
