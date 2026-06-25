# WhisperNote — Pipeline Tasks

## Core pipeline (this session)

- [x] **Merge fix** — `AudioRecorder.swift`: rewrote `mergeAudioFiles` to use `AVAssetExportPresetAppleM4A`, removed dead CMTimeMapping block, surface export error via `throw`
- [x] **Error surfacing** — `AudioRecorder.swift`: added `@Published var lastError: String?`; `stopRecording` catch sets it and resets UI state; merge fallback warns instead of silent downgrade
- [x] **Import audio** — `AudioRecorder.swift`: `importRecording(from:)` copies file to recordings dir, reads duration via AVAsset, appends to recordings list
- [x] **Import UI** — `RecordingView.swift`: "Import Audio File" button + `.fileImporter` sheet + `.onChange(lastError)` feeds into existing alert
- [x] **API key leak** — `TranscriptionManager.swift`: removed `print("Using API key: ...")` console leak
- [x] **Retry button** — `SummaryView.swift`: `SummaryDetailView` Retry now deletes failed summary and calls `generateSummary` with original transcript/prompt/model

## Next session

- [ ] Migrate API keys from `@AppStorage` (UserDefaults) to Keychain
- [ ] Fix README: says macOS 12.0, should be 13.0
- [ ] Replace bundle ID `com.example.WhisperNote`
- [ ] Pin RecordKit to a tagged release (currently `branch: main`)
- [ ] RecordKit commercial license before App Store / distribution
- [ ] Apple notarization

## Smoke test checklist

1. `swift build` — must compile clean
2. Record short clip → Stop → confirm recording appears and `recording.m4a` exists on disk
3. Import Audio File → pick an `.m4a` → appears in recordings list → Transcribe button enabled
4. Generate Summary on a transcript → on failure, Retry triggers a new generation attempt
5. Transcribe a file → confirm no API key printed to console
