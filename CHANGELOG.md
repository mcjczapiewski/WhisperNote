# Changelog

## 1.3.4 — July 7, 2026

- Fixed system audio recording starting late (sometimes tens of seconds after the microphone), which threw off the merged recording's timing and truncated it to the shorter track. The system audio tap's aggregate device now anchors to the real default output device for its clock instead of relying on the tap alone, so it starts capturing immediately rather than waiting for audio playback to "wake up" the tap.

## 1.3.3 — July 7, 2026

- Fixed "Couldn't start recording" on mics with unusual sample rates (e.g. some voice-optimized USB/Bluetooth mics running at 16kHz) — the AAC encoder no longer gets a hardcoded bit rate that's invalid for the mic's actual format.

## 1.3.2 — July 7, 2026

- Reverted 1.3.1's Data Protection Keychain change — it requires an entitlement only available with a paid Apple Developer Team, which this unsigned build doesn't have, and broke saving API keys. API keys are stored in UserDefaults again.

## 1.3.1 — July 7, 2026

- Fixed repeated macOS Keychain password prompts by storing API keys in the Data Protection Keychain instead of the legacy login keychain.

## 1.3.0 — July 7, 2026

- Replaced RecordKit with native Core Audio process taps and AVAudioEngine for mic/system audio capture — no more paid SDK license needed to distribute builds.
- Raised the minimum macOS version to 14.2 for Core Audio process tap support.
- Removed the Screen Recording permission requirement for system audio capture.
- Pause now actually stops capturing audio, so the paused interval isn't in the resulting recording.

## 1.2.2 — July 7, 2026

- Prepared the project for public open-source release with updated README and license files.
- Moved API key storage from UserDefaults to the macOS Keychain.
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
