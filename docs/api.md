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
* `Authorization: Bearer <key>` carries the gateway's key. The key is baked
  into the package at build time from the `AIDICT_TOKEN` secret, the same way
  the address is — neither is in the repository. The gateway also accepts the
  key as `?token=<key>`, so it can ride inside the baked-in address instead
  and there is one secret to inject rather than two; the header is the better
  of the two, since a query string reaches access logs.
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
  "model": "openai/gpt-oss-120b",
  "timing": {
    "total_ms": 1800, "upstream_ms": 1750,
    "model_ms": 500, "review_ms": 350, "retry_ms": 900
  },
  "review": { "sense": 0.17, "examples": 1.33, "retried": true }
}
```

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

`timing` is the gateway's own account of where the time went. `total_ms` is the
whole handler, `upstream_ms` everything spent talking to other services, split
into `model_ms`, `review_ms` and `retry_ms`. The device times its round trip
separately, and the footer under an answer shows both: `5.0s total · 1.8s
server`. A single number cannot be acted on — three seconds of radio and three
of model look identical on the screen and want opposite fixes.

Two measurements, not three. The gap between them is the Wi-Fi waking, DNS,
the handshake, Cloudflare and the flight each way, taken off two different
clocks; calling it "network" would be a claim neither number supports.

`review` appears when the gateway took a second opinion on its own answer:
`sense` is 0..1 for "is this the sense the passage gives the word", `examples`
is 0..2 for how many of the three illustrate that same sense, and `retried`
says the answer above is the second attempt. A low `sense` makes the gateway
ask the model again; it never makes it withhold an answer, because the
reviewer raises a false alarm now and then.

None of it is shown. It goes in the log, where one lookup is one line:

```
aidict: founder ok in 1840ms (gateway 900ms: model 500ms, review 350ms, \
  openai/gpt-oss-120b) [aidict-68ce5f3a-9c41f2 cf=a3e2705c8ddcdda5-IAD]
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
* **Prefetch.** With it on, the device asks when the *dictionary* opens rather
  than when AI is pressed, so expect a request for every dictionary lookup and
  a hit rate well below one answer read per answer fetched. It is off by
  default for that reason. The request is identical either way.
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
