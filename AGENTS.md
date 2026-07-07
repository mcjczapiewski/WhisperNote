# WhisperNote — Developer Reference

Native macOS app for recording or importing spoken audio (mic + system audio), transcribing via ElevenLabs, and summarizing via OpenRouter LLMs. No bots, no meeting invites required.

---

## Build & Run

```bash
# From project root
swift build
swift run
```

**Platform:** macOS 14.2+  
**Bundle ID:** `com.czapiewski.whispernote`  
**Xcode:** Optional; project opens via `WhisperNote.xcodeproj` but SPM CLI is the primary workflow

## Change Workflow

For every repository change, update the app patch version, update the changelog, commit the changes, and push them to GitHub. Version numbers use `major.minor.patch` format, for example `1.2.1`.

Current app version source of truth: `MARKETING_VERSION` in `WhisperNote.xcodeproj/project.pbxproj`. Keep the fallback app version in `SettingsView.swift` aligned with it. The in-app changelog loads the canonical root `CHANGELOG.md` bundled by the Xcode project.

---

## Architecture

Four clean layers plus small UI/storage helpers. Each layer owns its concerns; the UI layer consumes the others.

| Layer       | Files                                                                                                                                      | Responsibility                                   |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| Audio       | `AudioRecorder.swift`, `SystemAudioCapture.swift`                                                                                          | Mic capture (AVAudioEngine) + system audio capture (Core Audio process tap), pause/resume, merge, import, audio-device helpers |
| API clients | `TranscriptionManager.swift`, `SummaryManager.swift`                                                                                       | ElevenLabs STT, grouped transcription, OpenRouter summaries and prompt enhancement |
| Persistence | `DirectoryManager.swift`, `Models.swift`, `TextDocument.swift`                                                                             | JSON storage, file paths, security-scoped folder bookmark, export documents |
| UI          | `ContentView.swift`, `RecordingView.swift`, `TranscriptView.swift`, `SummaryView.swift`, `SettingsView.swift`, `AudioSetupGuideView.swift` | SwiftUI 4-tab interface                          |
| Helpers     | `FinderHelper.swift`, `MarkdownTextRenderer.swift`, `ReadOnlyTranscriptTextView.swift`, `DebugLogger.swift`                                | Finder reveal actions, Markdown plain/print rendering, large transcript preview, local debug logs |

**State management:** `AudioRecorder` is a `@StateObject` passed app-wide via `.environmentObject`. `TranscriptionManager` and `SummaryManager` are `@StateObject`s owned by `ContentView` and passed to tabs via `.environmentObject`. Settings use `@AppStorage` (UserDefaults). All async work via `Task { }` + `await`.

---

## Dependencies (Package.swift)

| Package             | Version                            | Purpose                                                                 |
| ------------------- | ---------------------------------- | ----------------------------------------------------------------------- |
| `swift-markdown-ui` | ≥2.4.1                             | Markdown rendering in SummaryView                                       |

Mic and system audio capture use only Apple frameworks (AVFoundation + Core Audio process
taps, macOS 14.2+) — no third-party recording SDK, no distribution license required.

---

## API Services

### ElevenLabs (Transcription)
- `POST https://api.elevenlabs.io/v1/speech-to-text`
- Model: `scribe_v2`, multipart/form-data upload
- Supports: diarization (`diarize=true`), word timestamps, 80+ language codes
- Timeout: 1 hour request / 2 hour resource (large file uploads)
- API key stored locally in `UserDefaults` via Settings `@AppStorage`.

### OpenRouter (Summarization)
- `POST https://openrouter.ai/api/v1/chat/completions`
- Default model: `openai/gpt-4o-mini`
- Available models (see `Models.swift:llmModels`): DeepSeek v4 Flash, GPT-4o Mini, Gemini 3 Flash, GLM-5.2, Grok 4.3
- API key stored locally in `UserDefaults` via Settings `@AppStorage`.

---

## File Storage

Default base: `~/Documents/WhisperNote/Files/`  
Structure: `Recordings/`, `Transcripts/`, `Summaries/`  
Recorded sessions get a unique `recording_yyyyMMdd_HHmmss_UUID/` directory with `mic_recording.m4a` + `system_recording.m4a` merged into `recording.m4a`. Imported files get `import_yyyyMMdd_HHmmss_UUID/recording.<ext>` directories.  
Transcripts are stored in `Transcripts/transcripts.json` plus compact ElevenLabs JSON archives with speaker segments. Summaries are stored in `Summaries/summaries.json`.  
User can override the base directory in Settings (stored as a security-scoped bookmark).

---

## Console Warnings (Xcode)

These appear in the Xcode console but are OS/framework-level — no app code can suppress them:

| Warning                                                                    | Source                        | Notes                               |
| -------------------------------------------------------------------------- | ----------------------------- | ----------------------------------- |
| `Unable to obtain a task name port right for pid N`                        | macOS XPC / sandbox           | Benign IPC noise                    |
| `ViewBridge to RemoteViewService Terminated … NSViewBridgeErrorCanceled`   | SwiftUI popover plumbing      | Benign, expected on popover dismiss |
| `didChangeStateImage: rep returned item view with wrong item`              | SwiftUI menu internal diffing | Benign SwiftUI bug; no workaround   |
| `nw_protocol_instance_set_output_handler Not calling remove_input_handler` | Network.framework extension   | Benign network stack log            |
| `Unable to get synchronousRemoteObjectProxy … com.apple.linkd.autoShortcut` | App Intents / Shortcuts XPC  | Benign; louder under Xcode re-signing; no workaround |
| `AddInstanceForFactory … F8BB1C28-…` / `HALC_ShellObject … (nope)`        | Core Audio HAL                | Benign HAL device probe noise       |
| `CMIO_DAL_CMIOExtension_PlugIn … Connection invalid` / `appleh13camerad`  | CoreMediaIO camera subsystem  | ScreenCaptureKit pulls in the camera subsystem even though the app never uses the camera; benign |
| `cannot open file … /private/var/db/DetachedSignatures` / `Reporter disconnected` | macOS code signing / SQLite | Benign signing infrastructure noise; expected under Xcode |

---

## Known Issues To Verify

- **Save-on-stop crash/error** — no current confirmed repro after the Core Audio process tap + AVAudioEngine rewrite. If it resurfaces, inspect `AudioRecorder.stopRecording()`, `mergeAudioFiles(...)`, and `exportMixedAudio(...)`. Current behavior stops capture before merge, falls back to microphone audio if system audio merge fails, and surfaces `lastError` to the UI.
- **Grouped transcript retry lookup** — failed transcript retry can miss grouped recordings because it looks up a single `recordingId`; wire group retry only if needed.

---

## Pre-Distribution Checklist

- [ ] Audit debug console prints/logs before release; avoid logging API responses, sensitive file paths, or credentials
- [ ] Apple notarization (optional — see `RELEASE.md` for the unsigned-build alternative)

---

## Feature Status

**Complete:**
- Mic + system audio recording with merge
- Pause/resume that stops capture so paused intervals are excluded from the saved recording
- Single-file and grouped audio import
- Microphone selection before recording
- Live combined microphone/system-audio input meter
- System audio permission warm-up on app launch
- ElevenLabs transcription with speaker diarization
- Transcription language selection
- Grouped transcription into a single combined transcript
- OpenRouter summaries with model selection and custom prompts
- Prompt preview and prompt enhancement
- Export transcripts (.txt) and summaries (.txt, .md)
- Print / PDF export for summaries with Markdown rendering and configurable margins
- Custom recording directory
- Show in Finder actions for recordings, transcripts, and summaries
- Find & Replace in transcripts
- Editable summary text with Find & Replace
- Markdown rendering in summaries
- Retry failed summary generation
- In-app changelog loaded from `CHANGELOG.md`
- Local API key storage via Settings `@AppStorage`

**Not built (from PRD):**
- Live (real-time) transcription
- Calendar integration / meeting detection
- iOS companion app
