# The gateway contract

The plugin talks to one endpoint. This is what it sends and what it needs
back; the implementation belongs in `ai-small-projects` as a lib mounted on the
gateway (the gateway already path-routes `/cdx`, `/flights-mcp`, `/hevy-mcp`
and `/message-watcher` the same way, so `/koreader-ai` is one more mount).

## POST `<endpoint>/define`

The address is not written down in this repository: it is injected into the
package at build time from the `AIDICT_ENDPOINT` secret, and can be changed on
the device from the plugin's menu. Since 2026-09-22 it is a Cloudflare Worker
rather than a gateway mount — the same handler, answering at the edge at
roughly a third of the latency. The library kept its own address, which comes
only from `AIDICT_LIBRARY_ENDPOINT`: nothing derives one from the other.

### Request

```json
{
  "word": "founder",
  "context": "The main danger, according to many of these founders, was that the wrong people might \"have\" ASI. They talked of the need to win an \"AI arms race.\"",
  "sentence": "The main danger, according to many of these founders, was that the wrong people might \"have\" ASI.",
  "source_lang": "en",
  "title": "If Anyone Builds It, Everyone Dies",
  "author": "Yudkowsky, Soares",
  "client": "koreader-aidict",
  "client_version": "0.1.18"
}
```

* `word` is always present and never empty.
* `context` is the **paragraph** the word sits in, taken from the document's
  markup and stripped to plain text, trimmed to the reader's `context_chars`
  budget (1000 by default). A paragraph, rather than a sentence, is what lets
  the other side tell which sense is meant.
* `sentence` is the sentence inside that paragraph — which occurrence of the
  word is being asked about, when it appears more than once.
* Both are **omitted** when the document cannot produce them: a paged PDF has
  no paragraph markup, and a selection with nothing around it is not sent back
  as its own context.
* There is no language to choose. The reader reads in English and wants the
  word explained, not replaced, so the answer is English; `source_lang` is the
  book's language as KOReader knows it, which is often absent.
* `title` and `author` are there for disambiguation, not for logging.
* `Authorization: Bearer <key>` carries the gateway's key. Unlike the address,
  the key is **not** baked into the package: the package is published on a
  public site, and this key is the one token both mounts answer to, so a
  baked copy would be a published one. It is set on the device instead, under
  the plugin's "API key" setting. Both also accept it as
  `?token=<key>`, but the header is the better of the two: a query string
  reaches access logs, and packaging refuses an `AIDICT_ENDPOINT` or an
  `AIDICT_LIBRARY_ENDPOINT` carrying a query string precisely so the key
  cannot re-enter the package that way.
* `X-Request-Id` is minted by the device, one per lookup, shaped
  `aidict-<hex seconds>-<hex random>`. The gateway keeps it if it matches
  `[A-Za-z0-9._-]{1,64}`, stamps it onto every log line the request produces,
  and echoes it back in the response header of the same name. The device puts
  it in its own log line — so one lookup is one id on both sides.

  The device mints it rather than the gateway because a request that never
  arrives is the one worth correlating: the gateway may have answered after
  the Kindle gave up, and only the device's id ties the two halves together.

  Cloudflare sits in front of the gateway and stamps `CF-Ray` on both the
  request and the response. The device reads it off the answer and logs it
  next to its own id, and the gateway logs it as a field of its own — it is
  the key into Cloudflare's logs, which nothing else gives. It never replaces
  the device's id, because it exists only once the request arrived. When the
  device sends no id, the gateway adopts the ray rather than minting a uuid.

### Response, 2xx

```json
{
  "word": "founder",
  "definition": "A person who starts a company — here, the people who started the AI labs.",
  "examples": [
    "The founders met in a garage.",
    "She is a founder of two companies.",
    "The founders didn't talk about that."
  ],
  "translation": "основатель",
  "part_of_speech": "noun",
  "lemma": "founder",
  "pronunciation": "/ˈfaʊndər/",
  "etymology": "From Old French fonder, to lay a base for.",
  "forms": ["founders"],
  "model": "google/gemini-2.5-flash-lite",
  "timing": {
    "total_ms": 1100, "upstream_ms": 1080,
    "legs": { "sense": 350, "examples": 730 }
  }
}
```

### Two ways an answer is reached

The gateway holds a static dictionary — 477k headwords from GCIDE and English
Wiktionary — and tries it first. It already has the word's senses, so all that
is asked of a model is which of them the passage is using, and that is a
classification rather than a generation: about 350 ms, and the answer is one
of the dictionary's own lines or it is nothing. The definition, part of
speech, pronunciation, etymology and forms then come from a book, where they
cannot be invented. Only the examples are written, by a model that is told
which sense was chosen.

When the dictionary has no entry, or no sense that fits — English grows senses
faster than dictionaries record them — a model is asked to write the whole
entry instead, which is what always used to happen. It takes two to six
seconds against about one.

The device is told which happened by `timing.legs`, and nothing else in the
response changes shape.

`definition` and `examples` are **English**. Only `definition` is required — a
200 without a non-empty one is treated as a broken answer. `examples` is the
field the device is designed around: three short ones render well on a 600×800
screen; entries that are not non-empty strings are dropped.

`translation` is the Russian rendering. The plugin parses and caches it but
**does not show it yet** — how it should sit next to an English explanation is
still open. Everything else is optional and simply not shown when missing.

`lemma` is the headword a dictionary would file the answer under — the
infinitive for a verb, the singular for a noun. The reader taps an inflected
form and an entry titled with that form is an echo, not an entry, so the
window is titled with this instead and the tapped form appears beneath it when
the two differ. Which headword it is depends on the sense: "left" the verb
lemmatises to "leave" while "left" the direction stays "left".

`forms` is the inflected forms of the headword. The device marks the word in
each example, and rules about endings reach "strapped" from "strap" but never
"went" from "go". On the dictionary path these are the dictionary's own —
Wiktionary spells them out on its headword line — and on the model path the
model says which spellings it used. It may be empty, and the device then marks
what it can work out on its own.

`pronunciation` is IPA for the **lemma**, not for the form in the passage, and
sits on the headword's line the way a dictionary prints it. `etymology` is one
sentence, drawn last and quieter than the rest. Both may come back empty and
are then simply absent: a wrong pronunciation teaches a reader to say the word
wrongly, which is worse than saying nothing.

Every text field is stripped of emphasis markers before it is sent. The prompt
asks for plain text and mostly gets it, but "from Old Norse *vanta*" comes back
often enough to matter, and the device draws an asterisk as an asterisk.

`timing` is the gateway's own account of where the time went. `total_ms` is the
whole handler, `upstream_ms` everything spent talking to other services, and
`legs` splits that by the calls that actually ran. Which legs appear says which
path answered: `sense` and `examples` mean the dictionary had the word,
`model` — with `review` and `retry` behind it — means it did not. A leg that
did not run is absent rather than zero, because a named leg reads like a
measurement.

The device times its round trip separately, and the footer under an answer
shows both: `5.0s total · 1.8s server`. A single number cannot be acted on —
three seconds of radio and three of model look identical on the screen and
want opposite fixes.

Two measurements, not three. The gap between them is the Wi-Fi waking, DNS,
the handshake, Cloudflare and the flight each way, taken off two different
clocks; calling it "network" would be a claim neither number supports.

`review` appears only on the model path, when the gateway took a second
opinion on its own answer:
`sense` is 0..1 for "is this the sense the passage gives the word", `examples`
is 0..2 for how many of the three illustrate that same sense, and `retried`
says the answer above is the second attempt. A low `sense` makes the gateway
ask the model again; it never makes it withhold an answer, because the
reviewer raises a false alarm now and then.

None of it is shown. It goes in the log, where one lookup is one line:

```
aidict: founder ok in 1840ms (gateway 1100ms: examples 730ms, sense 350ms, \
  google/gemini-2.5-flash-lite) [aidict-68ce5f3a-9c41f2 cf=a3e2705c8ddcdda5-IAD]
```

Legs are listed longest first: a JSON object arrives as a Lua table with no
order at all, and the only reason to read this line is to find out what took
the time.

### Response, errors

Any non-2xx status. The body, when it is JSON, may carry a message that is
shown to the reader as-is:

```json
{ "error": { "message": "context too long" } }
```

`{"error": "context too long"}` and `{"message": "…"}` are read too.

The plugin maps the status to what it tells the reader:

| Status | What the reader sees |
| --- | --- |
| 401, 403 | the gateway rejected this device's key |
| 429 | too many requests, try again shortly |
| 5xx | the gateway failed (HTTP …) |
| anything else | unexpected response (HTTP …) |

A request that never gets a response is a network error, and one that times out
says so — the reader can dismiss the wait at any point, which kills the
subprocess doing the request.

## Notes for the gateway implementation

* **Timeouts.** The device gives up after 10s per block and 30s in total, both
  configurable. An answer that takes longer is simply lost, so the gateway
  should cap its own upstream call below that.
* **Every lookup asks.** The device asks as soon as the dictionary opens and
  shows the answer as the popup's first page, so expect a request for every
  dictionary lookup that is not already cached.
* **Caching.** The device caches answers for 30 days keyed on (word, context),
  so repeat traffic for the same passage does not reach the gateway at all.
  The same word in another paragraph is a different key, and asks again.
* **Size.** Keep the answer short. It is rendered in a text viewer on a
  600×800 e-ink screen; a paragraph plus three examples is the right shape.
* **Auth.** A single shared token is enough — this serves one reader. It is
  read from `Authorization: Bearer` or from `?token=`. `GET /health` stays
  open even when a token is set, so an uptime check does not need the key.
* **The answer.** `openai/gpt-oss-120b`, Cerebras preferred but not pinned,
  `reasoning: medium`, `part_of_speech` constrained to an enum. Then a second
  opinion from `typesafe/jev-1.13`, and a retry when it doubts the sense. On
  44 deliberately nasty words that took the model from 41 right to 44; the
  settings and the numbers behind them are in the gateway's own source.

## POST `<endpoint>/vocab`

The lookups the Kindle's own reader recorded in
`/mnt/us/system/vocabulary/vocab.db`, sent from the menu's "Send Kindle
lookups" or its gesture, after a confirmation that says how many lookups are
new; nothing new asks nothing. The device reads the file read-only and sends the
English-to-English lookups at or after `vocab_uploaded_through`, oldest first,
at most 100 per request:

```json
{
  "request_id": "0f8b5c1e-3a2d-4c6e-9b1f-2d4e6a8c0b1d",
  "rows": [{
    "lookup_id": "CR!…:6032", "position": "6032",
    "usage": "He was strapped into the seat.", "timestamp": 1760000000000,
    "word": "strapped", "stem": "strap", "lang": "en",
    "book_asin": "B000FC1PJI", "book_title": "A Book", "book_authors": "An Author"
  }]
}
```

`request_id` is a UUID v4, fresh per request. A NULL column is `""`. The
server passes the batch to the Words inbox's `POST /api/inbox/kindle`, which
keys each row on its lookup id, so a row sent twice is written once.

Answer, 200: `{ "created": 1, "existing": 0, "skipped": 0 }`. Errors come as
`{ "error": { "message": "…" } }`, as for `/define`: 401 for the key, 503 when
the server has no inbox configured, 502 when the inbox did not answer or
failed.

After each 2xx the device moves `vocab_uploaded_through` to the newest
timestamp that batch carried, and keeps it when a later batch fails. The
query is `>=`, so the last lookup is sent again next time and counted as
`existing`.

# The library contract

Still the gateway, and now its own address. `library_endpoint` is baked into
the package from `AIDICT_LIBRARY_ENDPOINT` and is not a setting: the menu shows
it and cannot change it. A `?token=` riding on it is kept at the end, where a
query has to be. Empty means the package was built without it, and the sync
says so rather than guessing.

The plugin used to carry one address and swap the last path segment —
`https://host/koreader-ai` became `https://host/koreader-library`. That day
came on 2026-09-22: the dictionary moved to a Cloudflare Worker and the
library stayed here, and a Worker address has no path segment to swap.

## GET `<library>/manifest`

Everything the gateway holds, in one request. The device does the diffing —
only the device knows what it already has — so there is no per-folder walk and
no listing credential on a Kindle.

```json
{
  "version": 1,
  "generated_at": "2026-09-21T11:00:00.000Z",
  "files": [
    {
      "path": "Lem/Solaris.epub",
      "size": 412345,
      "etag": "d41d8cd98f00b204",
      "url": "https://….r2.cloudflarestorage.com/…?X-Amz-Signature=…"
    }
  ]
}
```

* `path` is relative and carries the folders. They are mirrored under
  `library_dir`, which defaults to `/mnt/us/AI_Books` — its own folder beside
  Audible, Documents and Screenshots, named to sort above them. The sync
  creates it. `documents/` is deliberately not it: that is the one folder the
  Kindle's own framework indexes, and an EPUB in there becomes an entry in
  the native library that opens badly.
* `size` is what the device compares against. **Not existence**: a download
  the Kindle lost Wi-Fi halfway through leaves a file that is there and wrong,
  and "already have it" would keep it wrong for ever.
* `url` is fetched with **no Authorization header** — it is presigned, and a
  key beside a signed query is how a signature stops matching. A 401 or 403
  from it means the link expired, and the fix is another manifest.
* `etag` is how a moved or renamed book is recognised: see below. It is never
  compared to decide whether a book in place is current — size does that.
* `Authorization: Bearer <key>` or `?token=` gates the manifest itself, the
  same key the dictionary uses.

A row the device cannot use — a path that would climb out of the books folder,
a zero size, a URL that is not http — is dropped and counted rather than
failing the sync. The gateway applies the same rule on upload; the device
applies it again, because a device that trusts a server to have checked is a
device that stops working the day the server does not.

## Downloading

Each file lands as `<target>.part` and is renamed only once its size matches
the manifest. A sync that is interrupted leaves nothing the file browser will
show and nothing the next sync will mistake for a finished book.

Timeouts are the library's own — 30s per block, 600s total — rather than the
dictionary's: a 30 MB book over a Kindle's radio needs room that would be an
absurd wait for a word lookup.

## Moves and deletes

The manifest says only where each book is now; the device works out what
changed against its own index of what earlier syncs placed —
`aidict_library.lua` in KOReader's settings folder, one row per path with the
size and etag it had. Nothing else in the books folder is ever moved or
deleted, so a file put there by hand stays put. The index belongs to one
folder: choosing another books folder starts a fresh one. The first sync that
keeps one takes in every book already at a listed path with the listed size —
that is how books synced before there was an index can move at all — and so
also a hand-placed file that happens to match one exactly, which the device
cannot tell apart from the server's copy.

* **Moved.** A listed book missing at its path is looked for among the
  indexed paths the manifest no longer lists: same size, and the same etag —
  or, failing any etag match, the same file name. Found, it is moved rather
  than downloaded again, and its `.sdr`, History entry and collections move
  with it, exactly as KOReader's own cut-and-paste does. A whole folder moved
  on the server is that, book by book.
* **Deleted.** An indexed path the manifest no longer lists, that no book
  moved out of, is deleted the way KOReader's file manager deletes: the file,
  its sidecar, its History entry and its collections. "No longer lists"
  counts every row the manifest carried, including one this device dropped
  as unusable: the server still has that book, so the copy here stays. Nor is
  a path deleted when a listed path differs from it only in case — on the
  Kindle's FAT storage the two are one file, and deleting the old name would
  delete the book. A rename that only changes case therefore leaves the
  folder's old spelling on the device.
* A folder a move or delete leaves empty is removed; the books folder itself
  never is.
* **The open book is left alone.** The reader writes its sidecar to the path
  it opened when it closes, so it keeps its old path in the index and is
  moved or deleted by the next sync after it is closed.

The downloads run in a forked subprocess, so the reader can give up on a long
sync. The moves and deletes do not: they go through KOReader's History,
collections and book settings, which a child process would change only in its
own copy. They run back in KOReader once the downloads finish — but they are
planned before any download starts, so a moved book is never fetched again at
its new path.

## Notes for the gateway implementation

* **Nothing is automatic.** The reader presses *Sync library*. There is no
  poll, no timer and no sync on resume, so the gateway sees a request only
  when someone asked for one.
* **The manifest is generated, not stored.** Listing the bucket on each
  request is one API call and removes the question of what to do when a book
  is uploaded and an index is not rebuilt.
* **Presigned URLs keep the bytes out of the gateway.** They also mean the
  store stays private: no public bucket, no custom domain on it.
