# WhisperNote telemetry n8n handoff

Import these disabled workflows into a private staging n8n project:

- whispernote-telemetry-intake.json — authenticated HTTPS POST intake for health telemetry and explicit feedback.
- whispernote-telemetry-retention-cleanup.json — hourly removal of raw rows before they reach 90 days.

The files contain no real webhook URL, table ID, credential ID, token, or customer data. Do not put any secret in exported workflow JSON, a URL, a query string, or a user-editable app setting.

## Intake behavior

The intake Webhook is Header Auth, POST, Raw Body, and Respond to Webhook mode. Its admission nodes require application/json, measure the original body at 64 KiB or less, limit a batch to 20 items, reject a duplicate event_id anywhere in a batch before storage, parse timestamps and require their UTC date-and-time portion to round-trip canonically, allowlist all fields and enums, enforce v1 health-shape rules, reject install_id on feedback, limit trimmed feedback to 1 through 2,000 Unicode code points, and persist only allowlisted values plus server timestamps.

Data Table upsert matches on event_id. Repeated event IDs across separate requests are accepted and do not create another row. Repeated IDs in one batch are rejected before any storage or acknowledgement. A valid envelope returns HTTP 200 with contract_version, accepted_event_ids, and rejected entries containing a stable event ID and a closed reason_code. Invalid envelopes return HTTP 400 without echoing a request value. An unavailable Data Table returns no acknowledgement, allowing a client retry with stable event IDs.

Health and feedback use separate tables. This package does not enrich, forward, email, or notify on feedback.

## Version-dependent imports

The package was written for current n8n node forms: Webhook 2.1, Code 2, Data Table 1.1, Respond to Webhook 1.4, and Schedule Trigger 1.2. Import into staging first. Data Table resource IDs and selector UI vary by instance and n8n version, so every such value is an intentional placeholder rather than an invented ID.

Data Table upserts finish before an acknowledgement is sent. n8n does not document an atomic multi-row Data Table transaction: a mid-batch failure returns no acknowledgement and a retry safely upserts the same IDs. This is idempotent at-least-once storage, not an atomic all-20-row commit. Use a transaction-capable database workflow if strict batch atomicity is a release requirement.

n8n documents Data Tables as light-to-moderate storage, with a default instance-wide 50 MB limit. Monitor capacity before production.

## Configure the two tables

1. In the project Data Tables tab, create two private tables from scratch:
   - whispernote_health_v1
   - whispernote_feedback_v1
2. Create the following columns in both tables. Use string for every column except schema_version, which is number.

| Column |
| --- |
| event_id |
| kind |
| schema_version |
| occurred_at |
| app_version |
| app_build |
| os_version |
| install_id |
| event_name |
| stage |
| outcome |
| duration_bucket |
| failure_bucket |
| week_start |
| category |
| message |
| received_at |
| expires_at |

Both tables use the same schema because the validated kind chooses the destination. Empty strings are normal for fields that do not apply. Keep the tables separate and access-restricted.

3. Obtain actual table IDs with the Data Table selector or the table URL exposed by the installed n8n version. Do not reuse another environment's IDs.
4. In the intake workflow, open Validate v1 batch. Replace only these two literal strings at the top of its Code node:

~~~text
__REPLACE_WITH_HEALTH_DATA_TABLE_ID__
__REPLACE_WITH_FEEDBACK_DATA_TABLE_ID__
~~~

5. In the cleanup workflow, replace the matching placeholders in Delete expired health rows and Delete expired feedback rows. Keep Resource Locator mode set to id.
6. Confirm the intake Data Table operation remains upsert with event_id as its only equality filter. Do not change it to insert.

## Configure Header Auth

1. Create an n8n credential of type Header Auth named WhisperNote telemetry header.
2. Header name: X-WhisperNote-Token.
3. Header value: a freshly generated high-entropy random secret. Store it only in the n8n credential store and the application release configuration.
4. On WhisperNote intake webhook, select that credential. The imported credential entry is deliberately invalid.
5. Keep Header Auth, POST, Raw Body, and Respond to Webhook mode enabled. Publish only after staging tests pass.

n8n shows a test URL while listening and a production URL after publishing. Only use the test URL for staging. The app must use the production HTTPS URL.

## Retention and execution data

The intake workflow sets an expiry field to 89 days after server receipt. The cleanup workflow is independently authoritative: it runs hourly at minute 15 UTC and deletes rows whose received_at is older than its UTC 89-day cutoff. Even if a row misses the first matching run, the next hourly run remains inside the 90-day maximum. Keep its workflow timezone set to UTC, activate it after table IDs are set, and test it against disposable expired rows.

Set instance execution-data policy to prevent requests surviving in n8n execution storage:

~~~text
EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
EXECUTIONS_DATA_SAVE_ON_ERROR=none
EXECUTIONS_DATA_SAVE_ON_PROGRESS=false
EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=false
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=2160
~~~

2160 hours is 90 days. On hosted versions without environment configuration, set the equivalent global execution settings. After a staging run, verify successful, failed, and manual executions retain no body, raw binary, header, URL, or response. If external binary storage is configured, apply a lifecycle rule of 90 days or less there too.

Set a 90-day maximum for n8n backups, point-in-time recovery, reverse-proxy/CDN logs, observability stores, Data Table exports, dashboards, and restored copies. Disable request-body logging. Redact X-WhisperNote-Token, webhook paths, and headers from operator logs. Do not enable feedback email alerts unless their storage has an equivalent verified retention limit.

## Application release values

After staging passes, provide the app team these values through the normal release secret/configuration channel:

~~~text
Telemetry endpoint: https://your-n8n-host.example/webhook/whispernote/v1
Header name: X-WhisperNote-Token
Header value: the Header Auth credential value
~~~

The endpoint must be HTTPS with no credentials, query, or fragment. It must not appear in UI or diagnostics. Both health and feedback batches use application/json and the same Header Auth value. Do not enable live delivery until staging, production endpoint configuration, retention policy, and a production smoke submission are verified.

## Staging curl checks

Set terminal-local values only. Do not put a production token in shell history, tickets, or this repository.

~~~sh
export WEBHOOK_URL='https://your-n8n-host.example/webhook-test/whispernote/v1'
export WHISPERNOTE_TOKEN='replace-with-staging-token'
~~~

Valid health event:

~~~sh
curl --silent --show-error --include \
  --header 'Content-Type: application/json' \
  --header "X-WhisperNote-Token: $WHISPERNOTE_TOKEN" \
  --data-raw '{"contract_version":1,"batch_id":"11111111-1111-4111-8111-111111111111","sent_at":"2026-07-15T12:00:00Z","items":[{"kind":"health_event","event_id":"22222222-2222-4222-8222-222222222222","schema_version":1,"occurred_at":"2026-07-15T12:00:00Z","app_version":"1.4.6","app_build":"1","os_version":"14.2","install_id":"33333333-3333-4333-8333-333333333333","event_name":"stage_outcome","stage":"transcription","outcome":"success","duration_bucket":"5_15s"}]}' \
  "$WEBHOOK_URL"
~~~

Expected: HTTP 200 and accepted_event_ids contains the health event ID.

Valid explicit feedback:

~~~sh
curl --silent --show-error --include \
  --header 'Content-Type: application/json' \
  --header "X-WhisperNote-Token: $WHISPERNOTE_TOKEN" \
  --data-raw '{"contract_version":1,"batch_id":"44444444-4444-4444-8444-444444444444","sent_at":"2026-07-15T12:01:00Z","items":[{"kind":"feedback","event_id":"55555555-5555-4555-8555-555555555555","schema_version":1,"occurred_at":"2026-07-15T12:01:00Z","app_version":"1.4.6","app_build":"1","os_version":"14.2","category":"usability","message":"Synthetic staging feedback only."}]}' \
  "$WEBHOOK_URL"
~~~

Expected: HTTP 200, one feedback-table row, and no generated install ID.

Repeat the first request unchanged. It must acknowledge the same ID and leave exactly one health-table row.

For unknown-key rejection, add a forbidden property to the feedback item. Expected: HTTP 200, no accepted ID, a rejected entry with reason_code unknown_field, and no stored row. For partial acceptance, send one valid item and one valid-UUID item with that forbidden property. Expected: only the valid ID is accepted and only one row is stored.

For the duplicate-batch smoke case, duplicate the health item inside the same items array without changing its event_id. Expected: HTTP 400, no Data Table write, and a duplicate_event_id rejection. Change occurred_at to 2026-02-30T12:00:00Z for the canonical-timestamp smoke case; expected: HTTP 400 and no write. Add install_id to the feedback item for the feedback-identity smoke case; expected: HTTP 400 and no write.

## Required pre-release evidence

Before production activation, demonstrate:

1. A body over 64 KiB returns HTTP 400 with no rows.
2. A 21-item batch returns HTTP 400 with no rows.
3. A 2,001-character feedback message is rejected as invalid_message.
4. Missing/wrong Header Auth fails before the workflow executes.
5. A batch containing the same valid event_id twice returns HTTP 400, writes no rows, and reports duplicate_event_id.
6. A timestamp such as 2026-02-30T12:00:00Z returns HTTP 400 and writes no rows.
7. Feedback carrying install_id returns HTTP 400 and writes no rows.
8. A temporary Data Table outage sends no accepted acknowledgement; recovery plus the same request yields one row per event ID.
9. A row approaches 89 days, then is deleted by the hourly cleanup before it reaches 90 days in both tables.
10. Execution records, logs, exports, and backups contain no request headers, webhook URL, or synthetic canaries.

## Rate limiting

The app contract supports HTTP 429 and Retry-After. This workflow intentionally does not rate-limit by IP, install ID, or feedback text because those are privacy-sensitive or unavailable for feedback. If ingress rate limiting is needed, configure an auth-aware gateway that returns HTTP 429 with numeric Retry-After while disabling IP/request retention. Test that behavior in staging. Do not add source IP, user agent, geolocation, account, or fingerprint to the tables.

## Operator checklist

- [ ] Both workflows imported and inactive until configured.
- [ ] Health and feedback tables are separate and access-restricted.
- [ ] Real target-environment table IDs are configured.
- [ ] Header Auth uses X-WhisperNote-Token and is selected on the intake node.
- [ ] Execution, binary, proxy, backup, export, and log retention are all at most 90 days.
- [ ] Contract, duplicate, timestamp, feedback-identity, partial, outage, oversize, 429, and under-90-day cleanup tests pass.
- [ ] Only then are the production URL and token released to the app configuration.
