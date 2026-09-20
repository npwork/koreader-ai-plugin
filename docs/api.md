# The gateway contract

The plugin talks to one endpoint. This is what it sends and what it needs
back; the implementation belongs in `ai-small-projects` as a lib mounted on the
gateway (the gateway already path-routes `/cdx`, `/flights-mcp`, `/hevy-mcp`
and `/message-watcher` the same way, so `/koreader-ai` is one more mount).

## POST `<endpoint>/define`

Default endpoint: `https://gateway.example/koreader-ai`.

### Request

```json
{
  "word": "fox",
  "context": "The quick brown fox jumps over the lazy dog",
  "target_lang": "ru",
  "source_lang": "en",
  "title": "Aesop's Fables",
  "author": "Aesop",
  "client": "koreader-aidict",
  "client_version": "0.1.0"
}
```

* `word` is always present and never empty.
* `context` is the sentence around the word, trimmed to the reader's
  `context_chars` budget. It is **omitted** when there is no surrounding text.
* `source_lang` is the book's language as KOReader knows it, which is often
  absent.
* `title` and `author` are there for disambiguation, not for logging.
* `Authorization: Bearer <key>` is present only when the reader set a key.

### Response, 2xx

```json
{
  "word": "fox",
  "definition": "A small wild animal of the dog family, known for cunning.",
  "translation": "лиса",
  "part_of_speech": "noun",
  "examples": ["The fox ran across the field."],
  "model": "claude-haiku-4-5"
}
```

Only `definition` is required — a 200 without a non-empty `definition` is
treated as a broken answer. Everything else is optional and simply not shown
when missing. `examples` entries that are not non-empty strings are dropped.

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
* **Caching.** The device caches answers for 30 days keyed on
  (word, context, target language), so repeat traffic for the same passage does
  not reach the gateway at all.
* **Size.** Keep the answer short. It is rendered in a text viewer on a
  600×800 e-ink screen; a paragraph plus two examples is the right shape.
* **Auth.** A single shared bearer token is enough — this serves one reader.
