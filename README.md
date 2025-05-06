# WhisperNote

WhisperNote is a native macOS app that allows users to record meetings in real-time—capturing both microphone and system audio—without requiring bots or meeting invites. After recording, it transcribes the audio using ElevenLabs' Speech-to-Text API and allows the user to generate a summary using a language model of their choice via OpenRouter.

## Features

- **Audio Recording**
  - Capture microphone audio
  - Capture system audio (requires virtual audio driver)
  - Save recordings as .wav or .mp3
  - Simple controls to Start, Pause, Stop, and Save recordings
  - Auto-save fallback in case of crash or shutdown

- **Transcription (ElevenLabs API)**
  - Upload saved audio files to ElevenLabs API
  - Show progress during transcription
  - Display full transcript after completion
  - Store transcripts locally and allow export as .txt

- **Summarization (OpenRouter + LLMs)**
  - Select preferred LLM (e.g., GPT-4, Claude, Mistral) via OpenRouter
  - Generate meeting summaries from transcripts
  - View summaries in a separate section
  - Export summaries as .txt or .md
  - Option to regenerate or fine-tune summary prompt

## Requirements

- macOS 12.0 or later
- Xcode 14.0 or later (for development)
- ElevenLabs API key
- OpenRouter API key
- Virtual audio driver (e.g., BlackHole or Loopback) for system audio capture

## Setup

1. Clone the repository
2. Open the project in Xcode
3. Build and run the app
4. In the Settings tab, enter your API keys for ElevenLabs and OpenRouter
5. Configure your preferred audio settings

## System Audio Setup

To capture system audio, you'll need to install a virtual audio driver like BlackHole or Loopback. Follow these steps:

1. Install BlackHole (free) or Loopback (paid)
2. Configure your system audio to output to the virtual audio device
3. In WhisperNote, select the virtual audio device as the input source

## Usage

1. **Recording**
   - Click "Start Recording" and provide a name for your recording
   - Use the pause/resume and stop buttons to control the recording
   - Recordings are automatically saved to your Documents folder

2. **Transcription**
   - Select a recording from the list
   - Click "Transcribe" to send the audio to ElevenLabs for transcription
   - View the transcript in the Transcripts tab once processing is complete

3. **Summarization**
   - Select a transcript from the list
   - Click "Generate Summary" to create a summary using your preferred LLM
   - View the summary in the Summaries tab
   - Optionally customize the prompt for different summary styles

## Privacy and Security

- All recordings and transcriptions are stored locally on your device
- API keys are securely stored in the macOS Keychain
- No data is shared with third parties without your explicit action

## License

[MIT License](LICENSE)

## Acknowledgements

- ElevenLabs for their Speech-to-Text API
- OpenRouter for providing access to various LLMs
- BlackHole/Loopback for system audio capture capabilities
