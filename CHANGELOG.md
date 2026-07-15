# Changelog

## 1.4.9 — July 15, 2026

- Fixed unified-search result links so each one opens the exact highlighted sentence that was clicked.

## 1.4.8 — July 15, 2026

- Added next/previous controls for read-only document search and deep links from each one-sentence unified-search result directly to its highlighted match.
- Made unified search responsive during typing, removed the global processing bar, and added Open actions for every recording with a completed transcript.
- Added optional transcript removal when deleting recordings, plus per-recording Auto Transcribe language selection.

## 1.4.7 — July 15, 2026

- Added a per-recording Record to Results choice at recording start, read-only search with highlighted matches in transcript and summary details, and aligned two-row detail toolbars.
- Added context previews for every matching sentence in unified search, Command-click bulk deletion in library lists, and moved Settings to the final tab.

## 1.4.6 — July 15, 2026

- Added an explicit, off-by-default health-telemetry consent flow with a local 30-day queue, privacy-preserving install identifier, secure Keychain delivery token, and opt-out purge.
- Added in-app product feedback that uses the same user-configured HTTPS endpoint without collecting contact details.
- Added an importable n8n telemetry intake and retention-cleanup package, with documented 90-day server retention and Data Table setup.

## 1.4.5 — July 14, 2026

- Added reusable local summary templates with five built-in presets: Meeting Minutes, Action Items, Client Follow-up, Interview Notes, and Learning Notes.
- Added template creation, custom-template editing and deletion, duplication, reordering, and per-library default selection, including safe Meeting Minutes fallback behavior.
- Added exact prompt, model, and template-provenance snapshots for interactive summaries and Record to Results so retries remain compatible and reproducible after later template changes.
- Added template-backed prompt drafts with explicit save/update actions and stale-safe prompt enhancement, plus transactional regeneration that preserves the prior summary if replacement fails.
- Made template stores participate in custom-library preflight, mutation draining, rollback, and atomic rebind so independent libraries cannot merge or receive cross-library writes.

## 1.4.4 — July 14, 2026

- Added unified offline search across recordings, transcripts, summaries, processing states, and tags.
- Added favorites and reusable tags with status, date, favorite, and tag filters plus deep links to matching library items.
- Added an atomic metadata sidecar and an in-memory search index for durable organization and responsive library queries.

## 1.4.3 — July 14, 2026

- Added an always-available menu bar controller for quick recording, pause/resume, stop, duration, permissions, processing status, results, and window navigation.
- Added an optional configurable global recording shortcut, disabled by default, with ⌥⌘R as the suggested binding and collision-safe Carbon registration without Accessibility permission.
- Unified recording lifecycle commands and app-root service ownership so the main window, menu bar, and shortcut share one durable session and one Record to Results handoff.

## 1.4.2 — July 14, 2026

- Added optional Record to Results automation that can transcribe and summarize a successfully saved live recording with snapshotted language, model, and Meeting Minutes prompt settings.
- Added durable, retryable processing jobs with stable transcript and summary identities, actionable missing-key states, cancellation, relaunch recovery, and notification-safe completion.
- Added persistent processing status, per-recording actions, and direct navigation to Settings or completed transcript and summary results.

## 1.4.1 — July 14, 2026

- Added atomic recording-session manifests and launch recovery so interrupted recordings can be finalized without duplicate library entries.
- Made recording start and stop awaitable, consolidated duplicate start handling, and added recover, retry, Finder, and dismiss actions for preserved sessions.
- Added staged audio imports with rollback and explicit batch partial-failure reporting.
- Made recording deletion transaction-safe, added exact legacy-session migration and crash reconciliation for imports, and rejected unsafe recovery-manifest paths.
- Serialized recovery actions and separated raw-track recovery from explicit combined-audio merge retries.
- Added offline coverage for manifest states, recovery file combinations and merge fallback, lifecycle idempotency, import rollback, and a generated short-audio integration fixture.

## 1.4.0 — July 14, 2026

- Added an offline XCTest foundation for Swift Package Manager with model compatibility, processing status, and language-model configuration coverage.
- Added a hosted macOS unit-test target to the Xcode project to validate app-module integration.
- Added release-invariant tests that keep the Xcode marketing version, in-app fallback version, and changelog heading aligned.

## 1.3.2 — July 7, 2026

- Added live system audio level reporting to the existing recording input meter, combined with microphone level without changing recorded audio volume.
- Request system audio recording permission during app launch instead of waiting until the first recording starts.
- Darkened recording, transcript, and summary list rows with solid non-glossy backgrounds for better separation from the app window.
- Matched the read-only transcript preview background to the summary preview/app background while leaving edit views unchanged.

## 1.3.1 — July 7, 2026

- Muted the first 0.97 seconds of microphone input on recording start and resume to suppress the measured Bluetooth/input-device activation pop while preserving recording duration and sync.

## 1.3.0 — July 7, 2026

- Replaced RecordKit with native Core Audio process taps and AVAudioEngine for mic/system audio capture — no more paid SDK license needed to distribute builds.
- Raised the minimum macOS version to 14.2 for Core Audio process tap support.
- Removed the Screen Recording permission requirement for system audio capture.
- Pause now actually stops capturing audio, so the paused interval isn't in the resulting recording.

## 1.2.2 — July 7, 2026

- Prepared the project for public open-source release with updated README and license files.
- Reduced release-time debug logging and tightened app entitlements.

## 1.2.1 — July 7, 2026

- Added editable summary text in the Summaries tab, including find and replace support.
- Updated project agent instructions and added AGENTS.md.

## 1.2 — July 1, 2026

- Added Show in Finder actions for recordings, transcripts, and summaries.
- Added a live microphone input level meter while recording.
- Improved summary text export so plain text exports remove Markdown markers while Markdown exports keep them.
- Improved Print / PDF summaries with formatted Markdown rendering and configurable margins.
- Kept summaries stored in summaries.json and removed individual summary files.

## 1.1.1 — July 1, 2026

- Added prompt enhancement to the Regenerate Summary dialog in the Summaries tab.

## 1.1 — July 1, 2026

- Added prompt preview before summary generation.
- Added editable summary prompts, so custom changes are used when generating a summary.
- Added prompt enhancement using the selected OpenRouter model.
- Renamed Meeting Type to Recording Type and made summary prompts work better for meetings, workshops, lectures, interviews, and other recordings.
- Improved large transcript viewing performance with a native macOS read-only text view.
- Changed transcript export so export files are prepared only when Export is clicked.
- Added compact transcript JSON archives and migration for older full ElevenLabs JSON response files.
- Removed a debug console message that printed saved transcript JSON file paths.

## 1.0 — Initial release

- Record microphone and system audio.
- Transcribe recordings with ElevenLabs.
- Generate summaries with OpenRouter language models.
- Export transcripts and summaries.
- Choose a custom recordings directory.
- Find and replace transcript text.
