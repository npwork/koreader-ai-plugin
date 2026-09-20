# The gateway contract

The plugin talks to one endpoint. This is what it sends and what it needs
back; the implementation belongs in `ai-small-projects` as a lib mounted on the
gateway (the gateway already path-routes `/cdx`, `/flights-mcp`, `/hevy-mcp`
and `/message-watcher` the same way, so `/koreader-ai` is one more mount).

## POST `<endpoint>/define`

The address is not written down in this repository: it is injected into the
package at build time from the `AIDICT_ENDPOINT` secret, and can be changed on
the device from the plugin's menu.

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
* `Authorization: Bearer <key>` is present only when the reader set a key.
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
  "model": "claude-haiku-4-5",
  "timing": { "total_ms": 900, "upstream_ms": 850 }
}
```

`definition` and `examples` are **English**. Only `definition` is required — a
200 without a non-empty one is treated as a broken answer. `examples` is the
field the device is designed around: three short ones render well on a 600×800
screen; entries that are not non-empty strings are dropped.

`translation` is the Russian rendering. The plugin parses and caches it but
**does not show it yet** — how it should sit next to an English explanation is
still open. Everything else is optional and simply not shown when missing.

`timing` is the gateway's own account of where the time went: `upstream_ms` is
the model call, `total_ms` the whole handler. The device times its round trip
separately, so the difference between the two is the network and the Kindle's
radio. It ends up in the log, not on screen:

```
aidict: founder ok in 1840ms (gateway 900ms, model 850ms, claude-haiku-4-5)
```

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
* **Caching.** The device caches answers for 30 days keyed on (word, context),
  so repeat traffic for the same passage does not reach the gateway at all.
  The same word in another paragraph is a different key, and asks again.
* **Size.** Keep the answer short. It is rendered in a text viewer on a
  600×800 e-ink screen; a paragraph plus three examples is the right shape.
* **Auth.** A single shared bearer token is enough — this serves one reader.
  `GET /health` stays open even when a token is set, so an uptime check does
  not need the device's key.
