# Claude API notes for the sheet-music transcription (OMR) provider

The Import module calls the Claude API over raw HTTPS with `URLSession` (there is no official
Swift SDK). These are the exact request shapes to use; do not improvise others.

## Endpoint and headers

```
POST https://api.anthropic.com/v1/messages
Content-Type: application/json
x-api-key: <user's key, stored in the Keychain>
anthropic-version: 2023-06-01
```

## Model and reasoning controls

- Model id: `claude-opus-5-5` (default). Allow an override in Settings; `claude-sonnet-5-5` is the
  cheaper alternative. Never append date suffixes to model ids.
- Thinking is always on for these models. Do **not** send a `thinking` object. Control depth with
  `"output_config": {"effort": "high"}` (allowed: low, medium, high, xhigh, max). Use `high` for
  transcription, `medium` for repair passes.
- `max_tokens`: 16000 for a page (non-streaming). The compact score JSON for one page is well under that.
- Request timeout: set `URLSessionConfiguration.timeoutIntervalForRequest` to 600 s; transcription of
  a dense page can take a couple of minutes.

## Request body: one page image

```json
{
  "model": "claude-opus-5-5",
  "max_tokens": 16000,
  "output_config": {
    "effort": "high",
    "format": { "type": "json_schema", "schema": { ...LPC schema from docs/import-format.md... } }
  },
  "system": "<transcription instructions>",
  "messages": [
    { "role": "user", "content": [
      { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": "<base64, no newlines>" } },
      { "type": "text", "text": "Transcribe this page of piano sheet music ..." }
    ] }
  ]
}
```

- Images: JPEG, PNG, GIF, WebP. Render PDF pages to PNG at a long edge of 2576 px (the model's
  high-resolution limit); do not downsample below ~1600 px or small accidentals are lost.
- A PDF can also be sent directly as a document block
  `{"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": "..."}}`
  but page-by-page PNG rendering gives better control (one request per page or per two pages, and the
  review screen can show the exact page next to the result). Use PNG rendering.
- Structured output (`output_config.format` with `type: json_schema`) guarantees the reply validates
  against the schema. The schema must have `"additionalProperties": false` on every object and list
  every property in `required`. Keep the schema small; the LPC format in `docs/import-format.md` is
  designed for this.

## Reading the response

```json
{ "content": [ { "type": "text", "text": "{ ...json... }" } ], "stop_reason": "end_turn", "usage": {...} }
```

- Check `stop_reason` first. `end_turn` → parse the first `text` block as JSON. `max_tokens` → the
  output was cut off: retry with the page split in two halves. `refusal` → show the user
  "the model declined this page" (rare for sheet music). Any other value → treat as failure.
- Iterate `content` and take blocks whose `type == "text"`; thinking blocks may also be present and
  must be ignored.
- HTTP errors: 401 invalid key, 429 rate limited (retry after the `retry-after` header, max 3 tries),
  529 overloaded (same), 400 → surface the `error.message` field to the user, 5xx → retry.

## Repair pass

If the app's structural validation of the returned LPC JSON fails (a measure does not add up, a tie
has no partner, a pitch is out of range), send a second request with the same image, the previous
JSON, and the list of errors, asking for a corrected full JSON. At most two repair rounds; after
that keep the best attempt and mark the failing measures as low confidence so the review screen
highlights them.

## Prompt-caching note

Put the long static transcription instructions in `system` and the page-specific text last; keep the
system text byte-identical between requests so the prefix can be cached. Not required for
correctness.
