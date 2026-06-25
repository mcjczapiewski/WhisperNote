# WhisperNote — Developer Reference

Native macOS app for recording meetings (mic + system audio), transcribing via ElevenLabs, and summarizing via OpenRouter LLMs. No bots, no meeting invites required.

---

## Build & Run

```bash
# From project root
swift build
swift run
```

**Platform:** macOS 13.0+  
**Bundle ID:** `com.example.WhisperNote` — placeholder, replace before any distribution  
**Xcode:** Optional; project opens via `WhisperNote.xcodeproj` but SPM CLI is the primary workflow

---

## Architecture

Four clean layers. Each layer owns its concerns; the UI layer consumes the others.

| Layer       | Files                                                                                                                                      | Responsibility                                   |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| Audio       | `AudioRecorder.swift`, `SystemAudioCapture.swift`                                                                                          | RecordKit capture/merge plus audio-device helpers |
| API clients | `TranscriptionManager.swift`, `SummaryManager.swift`                                                                                       | ElevenLabs STT, OpenRouter LLM                   |
| Persistence | `DirectoryManager.swift`, `Models.swift`, `TextDocument.swift`                                                                             | JSON storage, file paths, export                 |
| UI          | `ContentView.swift`, `RecordingView.swift`, `TranscriptView.swift`, `SummaryView.swift`, `SettingsView.swift`, `AudioSetupGuideView.swift` | SwiftUI 4-tab interface                          |

**State management:** `AudioRecorder` is a `@StateObject` passed app-wide via `.environmentObject`. API managers are created per-view as `@StateObject`. Settings use `@AppStorage` (UserDefaults). All async work via `Task { }` + `await`.

---

## Dependencies (Package.swift)

| Package             | Version                            | Purpose                                                                 |
| ------------------- | ---------------------------------- | ----------------------------------------------------------------------- |
| `RecordKit`         | branch: main (v0.45.0 XCFramework) | Mic + system audio capture — **requires paid license for distribution** |
| `swift-markdown-ui` | ≥2.4.1                             | Markdown rendering in SummaryView                                       |

RecordKit is pinned to `main` branch — a moving target. Pin to a tagged release before shipping.

---

## API Services

### ElevenLabs (Transcription)
- `POST https://api.elevenlabs.io/v1/speech-to-text`
- Model: `scribe_v2`, multipart/form-data upload
- Supports: diarization (`diarize=true`), word timestamps, 80+ language codes
- Timeout: 5 minutes (large file uploads)
- Key stored: `@AppStorage("elevenLabsApiKey")` — UserDefaults, not Keychain

### OpenRouter (Summarization)
- `POST https://openrouter.ai/api/v1/chat/completions`
- Default model: `openai/gpt-4o-mini`
- Available models (see `Models.swift:llmModels`): DeepSeek v4 Flash, GPT-4o Mini, Gemini 3 Flash, GLM-5.2, Grok 4.3
- Key stored: `@AppStorage("openRouterApiKey")` — UserDefaults, not Keychain

---

## File Storage

Default base: `~/Documents/WhisperNote/Files/`  
Structure: `Recordings/`, `Transcripts/`, `Summaries/`  
Each recording gets a UUID directory: `mic_recording.m4a` + `system_recording.m4a` → merged `recording.m4a`  
User can override directory in Settings (stored as security-scoped bookmark).

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

## Known Bugs

- **Save-on-stop crash/error** — error thrown when stopping a recording; investigate the stop + audio merge flow in `AudioRecorder.swift` around the `stopRecording()` method and the AVAssetExportSession merge logic
- **Retry button no-op** — `SummaryView.swift:354` has an empty callback for the failed-state retry button

---

## Pre-Distribution Checklist

- [ ] Remove debug API key prints: `AudioRecorder.swift:60`, `TranscriptionManager.swift:61`
- [ ] Migrate API keys from `@AppStorage` (UserDefaults) to Keychain — PRD requirement, not yet done
- [ ] Fix README: says macOS 12.0, should be 13.0
- [ ] Replace bundle ID `com.example.WhisperNote`
- [ ] Pin RecordKit to a tagged version (currently `branch: main`)
- [ ] RecordKit commercial license for App Store / distribution
- [ ] Apple notarization

---

## Feature Status

**Complete:**
- Mic + system audio recording with merge
- Pause/resume (timer-simulated — RecordKit has no native pause)
- ElevenLabs transcription with speaker diarization
- OpenRouter summaries with model selection and custom prompts
- Export transcripts (.txt) and summaries (.txt, .md)
- Custom recording directory
- Find & Replace in transcripts
- Markdown rendering in summaries

**Not built (from PRD):**
- Keychain storage for API keys
- Live (real-time) transcription
- Calendar integration / meeting detection
- iOS companion app
