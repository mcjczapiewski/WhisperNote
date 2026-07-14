# Changelog

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
