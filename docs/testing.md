# How this gets tested without a Kindle

Five layers, in the order of how much they cost. The first four run in any
Linux container; the fifth runs on a GitHub runner.

## 1. Units — `make test`

`spec/*_spec.lua`, run by busted under `lua5.1`. Covers `aidict/`: the API
client's request shape and every error it can map, the cache's LRU and TTL
behaviour against a fake clock, settings validation, the UTF-8 context window,
version comparison, formatting.

Nothing here touches a socket, a file or KOReader. Milliseconds.

The library sync is here too: `manifest_spec` on which paths may be
written, `plan_spec` on new/half-written/already-here, and `library_spec`
on the whole sync against a filesystem that is a table — including the
truncated download that must not become a book.

## 2. The KOReader layer — `spec/glue_spec.lua`

`main.lua` itself, against the stubs in `spec/support/koreader.lua`: KOReader's
class system, `UIManager`, `Trapper`, `NetworkMgr`, `LuaSettings`, the widgets.
The stubs record what the plugin did, so the specs press the real buttons and
assert on what was shown.

It covers what the emulator would otherwise be the only way to reach:

* the dictionary popup opens on the AI page: asking while the request is out,
  the answer once it lands, the error when it fails, and no page at all
  offline — with KOReader's own results still behind it,
* the highlight-dialog entry is registered and stays away when no document is
  open; pressing it sends the word *and the sentence around it*, and shows the
  answer in a TextViewer,
* the second tap on the same word is served from the cache, marked as cached,
  without a request,
* gateway errors and timeouts become an InfoMessage, not an answer,
* dismissing the wait shows nothing at all,
* being offline defers the lookup and re-runs it when the network comes back,
* the cache is written to settings and read back by the next session,
* the settings menu saves a valid endpoint, rebuilds the client with it, and
  refuses an invalid one,
* the update check asks the right channel URL and reports what it found.

This layer caught one real bug already: with no sentence available, the plugin
was sending the selected word as its own context.

## 3. Live HTTP — `spec/integration/http_spec.lua`

The same `http_transport.lua` that runs on the Kindle, over a real socket, to
`spec/support/fake_gateway.py`. `logger` and `socketutil` are the only stubs,
and `socketutil` does what KOReader's does: set luasocket's timeout.

Covers a real 200 with a parsed answer, what actually goes on the wire
(method, path, `Content-Type`, `Authorization`, the JSON body), a real 500 with
the gateway's message, a 401, a non-JSON body, a real timeout against a
deliberately slow endpoint, a refused connection, and a real update manifest.

## 4. The distribution — `make test-distribution`

`scripts/kpm-host-build.sh` builds **the real KPM** from
`KindleModding/kpm` against the host's libcurl, sqlite3, libarchive and
cJSON. (Upstream links those statically from meson subprojects a sandbox
cannot download, and pulls FBInk for the e-ink framebuffer; the script swaps in
pkg-config lookups and a no-op FBInk. Every line of KPM under test —
repository parsing, indexing, download, extraction, hooks — is upstream's.)

`scripts/test-distribution.sh` then serves a generated repository over HTTP on
localhost and drives that KPM through:

```
kpm add-repo http://127.0.0.1:8731/stable/manifest.json
kpm install koreader-aidict      -> the plugin lands in the fake koreader/plugins, version 0.1.0
kpm update && kpm upgrade        -> 0.1.1, and the file the old version left behind is gone
kpm uninstall koreader-aidict    -> the directory is gone
```

plus a check that every `sha256` in `manifest.json` matches its artifact, that
`SHA256SUMS` verifies, and that `version.json` points at the newest build.

It runs entirely in `.kpm/sandbox`; nothing goes near `/mnt/us`.

## 5. A real KOReader — `.github/workflows/koreader-smoke.yml`

On every push that touches `plugin/`, a GitHub runner downloads the latest
KOReader release, drops the plugin into it, and starts it headlessly under
`Xvfb`. The run fails unless KOReader's own log says `Plugin loaded aidict`
and says nothing about it erroring.

This is the check that keeps the stubs in layer 2 honest: if KOReader renames
`showDict` — the dictionary call the AI page hooks into — or changes how
plugins are loaded, this goes red even though every stub-based test still
passes. It does not open a popup, so the popup's insides (`results`,
`dict_index`, `changeDictionary`) are checked on the Kindle.

It lives in CI rather than in a cloud session because a session cannot
download a KOReader build — see [emulator.md](emulator.md).

## What is left for the real device

* KOReader actually loading the plugin on the device's own build — the stubs
  mirror the API, not the runtime.
* How the answer looks on e-ink at the device's font size.
* The Kindle's Wi-Fi sleeping mid-request.
* `;kpm install` typed into the search bar, against the real repository URL.

`docs/emulator.md` covers the middle ground: running a real KOReader here, and
what the cloud environment needs allowed first.
