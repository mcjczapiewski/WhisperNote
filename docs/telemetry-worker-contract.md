# Telemetry Ingress — Cloudflare Worker Contract

The app POSTs telemetry + feedback batches to a **baked-in default endpoint**
(`TelemetryController.defaultEndpoint`). That endpoint must be a public Cloudflare Worker that
sits in front of your private n8n webhook — never the raw n8n URL. The Worker is a transparent
proxy plus a few cheap guards, so **no app transport code changes** to add or change it.

Replace the placeholders in `WhisperNote/TelemetryController.swift` before release:
`defaultEndpoint` (the Worker route) and `defaultAppToken` (the shared app token below).

## Why a Worker (not the n8n URL directly)

A distributed macOS binary is trivially inspectable. Shipping the n8n URL + its auth secret
would leak both and let anyone spam your instance with no way to rotate without an app update.
The Worker keeps the n8n URL + secret server-side, rate-limits abuse, and lets you rotate or
block without shipping a new build.

**The baked-in `APP_TOKEN` is not a secret** — it ships in the binary and is only a bot
speed-bump. Real protection is (a) the hidden n8n URL/secret, (b) Worker rate limiting,
(c) server-side rotation.

## Request the app sends (fixed — do not change)

```
POST https://<worker>/ingest
Content-Type: application/json
X-WhisperNote-Token: <defaultAppToken>

{ "contract_version": 1, "batch_id": "<uuid>", "sent_at": "<ISO-8601 Z>", "items": [ … ] }
```

- ≤ 20 items, ≤ 64 KiB body, 15 s client timeout, ephemeral session, **redirects refused**
  (a 3xx breaks delivery — always answer directly).
- `items[]` are `kind: "health_event"` or `kind: "feedback"`. Never expected to contain audio,
  transcript/summary text, names, paths, credentials, or artifact IDs — do not add any.

## Response the app requires (v1 acknowledgement)

Return n8n's response **verbatim**; it MUST be:

```json
{
  "contract_version": 1,
  "accepted_event_ids": ["<uuid>"],
  "rejected": [{ "event_id": "<uuid>", "reason_code": "<closed-enum>" }],
  "retry_after_seconds": 300
}
```

`reason_code` ∈ `invalid_item | invalid_feedback | unsupported_contract | duplicate |
too_large | validation`. `retry_after_seconds` is optional (0–86400). Every id in
`accepted`/`rejected` must be one of the batch's `event_id`s and the two sets must be disjoint;
otherwise the app treats the ack as malformed and retries the same ids.

## Status-code behavior the app already implements

| Worker returns | App does |
|---|---|
| 2xx + valid ack | remove accepted ids; quarantine rejected ids |
| 413 | split the batch in half and retry |
| 429 / 408 / 5xx | retry with backoff, honoring `Retry-After` (cap 24 h) |
| 401 | pause delivery (authentication) |
| 403 | pause delivery (forbidden) |
| 404 | pause delivery (endpoint unavailable) |
| network error / other | retry the same ids |

Use these deliberately: return **429 + `Retry-After`** for rate limiting (nothing is lost),
**413** for oversize, and reserve 401/403/404 for genuine auth/route failures (they *pause* the
client until the app restarts).

## Worker responsibilities

1. **Method/type:** POST + `application/json` only → else 405 / 415.
2. **Size:** reject bodies > 64 KiB → **413**.
3. **App token (optional guard):** if `X-WhisperNote-Token !== env.APP_TOKEN` → **403**.
4. **Rate limit per IP:** Cloudflare Rate-Limiting rule on the route (or Worker + KV / Durable
   Object counter). On exceed → **429** + `Retry-After`.
5. **Cheap shape check:** JSON parses, `contract_version === 1`, `items.length <= 20`. Leave
   full allowlist validation to n8n.
6. **Forward:** send the body verbatim to `env.N8N_WEBHOOK_URL`, adding n8n's Header-Auth
   (`env.N8N_AUTH_HEADER_NAME: env.N8N_AUTH_HEADER_VALUE`). **Do not** forward the client IP.
7. **Return** n8n's status + body verbatim (the v1 ack). Pass through 413 / 429 / `Retry-After`
   / 5xx.
8. **Never log** request bodies, headers, tokens, or IPs.

## Secrets (`wrangler secret put`)

- `N8N_WEBHOOK_URL` — the real n8n webhook (production route).
- `N8N_AUTH_HEADER_NAME` / `N8N_AUTH_HEADER_VALUE` — n8n Header-Auth credential.
- `APP_TOKEN` — must equal `defaultAppToken` in the app.

Rotating any of these at the Worker takes effect with no app update.

## Rollout

1. Deploy the Worker to a **staging** route → a staging n8n workflow. Point
   `defaultEndpoint` at staging and run the E2E checks (enable telemetry → health event lands;
   feedback with telemetry off → arrives with no `install_id`; opt out → later feedback still
   delivers; trip 429 → app queues/retries; confirm no body/token/IP in logs).
2. Only then switch `defaultEndpoint` to the production Worker route and do one smoke
   submission.
