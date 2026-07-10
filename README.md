<div align="center">
  <img width="100" height="100" alt="AppIcon" src="https://github.com/user-attachments/assets/6fb84144-73ea-477c-b4f6-65956f8cbee8" />

  # WhisperNote

  WhisperNote is an open-source macOS app for recording, importing, transcribing, and summarizing spoken audio. It is built for macOS users who want a local-first workflow similar to Granola or MacWhisper, without adding meeting bots or inviting third-party assistants to calls.

  <img width="912" height="867" alt="app-main-tab" src="https://github.com/user-attachments/assets/4dcd9e2e-7a8b-4fb2-85e1-1d1b28a54229" />
</div>

## What It Does

- Record microphone and system audio on macOS.
- Choose a microphone, pause and resume capture, and monitor live input level.
- Import existing audio files, including multiple files grouped as one recording batch.
- Transcribe recordings with ElevenLabs Speech-to-Text, including language selection and speaker diarization.
- Generate summaries with OpenRouter language models.
- Edit transcripts and summaries, including find and replace.
- Export transcripts as `.txt`; export summaries as `.txt` or `.md`; print summaries or save them as PDFs.
- Save recordings, transcripts, and summaries locally by default.

## Requirements

- macOS 14.2 or later.
- ElevenLabs API key for transcription.
- OpenRouter API key for summaries.
- Xcode 15+ or Swift 5.9+ for development builds.

## API Keys

WhisperNote does not ship with API access. Add your own keys in Settings:

- ElevenLabs API key: used to upload selected audio for transcription.
- OpenRouter API key: used to send transcript text for summary generation.

API keys are stored locally in macOS app preferences and are only used when calling ElevenLabs or OpenRouter.

## Usage

1. Open WhisperNote and add your ElevenLabs and OpenRouter API keys in Settings.
2. Record a new meeting or import one or more audio files.
3. Transcribe a recording or grouped batch.
4. Generate a summary from the transcript using your selected OpenRouter model.
5. Edit, export, print, or save the result.

Importing grouped recordings is useful for voice recorder files, lecture recordings, interviews, or audio files shared by colleagues.

## Privacy

Recordings, transcripts, summaries, and metadata are stored locally on your Mac by default. Audio is sent to ElevenLabs only when you start transcription. Transcript text is sent to OpenRouter only when you generate, regenerate, retry, or enhance a summary prompt.

## Development

```bash
swift build
swift run
```

The Xcode project is included for app packaging and release builds.

## Releases

Download the latest macOS build from GitHub Releases when available. Builds are unsigned, so
macOS Gatekeeper quarantines them on first launch — right-click the app and choose **Open**
(then **Open** again in the dialog), or run:

```bash
xattr -dr com.apple.quarantine /Applications/WhisperNote.app
```

After the first launch it opens normally. Development builds from source require Xcode.

## License

WhisperNote is available under the MIT License. See [LICENSE](LICENSE).
