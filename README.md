# WhisperNote

WhisperNote is an open-source macOS app for recording, importing, transcribing, and summarizing spoken audio. It is built for macOS users who want a local-first workflow similar to Granola or MacWhisper, without adding meeting bots or inviting third-party assistants to calls.

## What It Does

- Record microphone and system audio on macOS.
- Import existing audio files, including multiple files grouped as one recording batch.
- Transcribe recordings with ElevenLabs Speech-to-Text.
- Generate summaries with OpenRouter language models.
- Edit transcripts and summaries, including find and replace.
- Export transcripts as `.txt` and summaries as `.txt` or `.md`.
- Save recordings, transcripts, and summaries locally by default.

## Requirements

- macOS 13.0 or later.
- ElevenLabs API key for transcription.
- OpenRouter API key for summaries.
- Xcode 15+ or Swift 5.9+ for development builds.
- RecordKit licensing if you distribute your own builds.

## API Keys

WhisperNote does not ship with API access. Add your own keys in Settings:

- ElevenLabs API key: used to upload selected audio for transcription.
- OpenRouter API key: used to send transcript text for summary generation.

API keys are stored in the macOS Keychain.

## Usage

1. Open WhisperNote and add your ElevenLabs and OpenRouter API keys in Settings.
2. Record a new meeting or import one or more audio files.
3. Transcribe a recording or grouped batch.
4. Generate a summary from the transcript using your selected OpenRouter model.
5. Edit, export, print, or save the result.

Importing grouped recordings is useful for voice recorder files, lecture recordings, interviews, or audio files shared by colleagues.

## Privacy

Recordings, transcripts, summaries, and metadata are stored locally on your Mac by default. Audio is sent to ElevenLabs only when you start transcription. Transcript text is sent to OpenRouter only when you generate or enhance a summary.

## Development

```bash
swift build
swift run
```

The Xcode project is included for app packaging and release builds.

## Releases

For normal users, download the latest signed and notarized macOS build from GitHub Releases when available. Development builds from source may require Xcode and local code-signing setup.

## License

WhisperNote is available under the MIT License. See [LICENSE](LICENSE).
