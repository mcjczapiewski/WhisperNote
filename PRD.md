Here’s a Product Requirements Document (PRD) for your macOS app that records meetings in real time, transcribes them using ElevenLabs, and provides meeting summaries via OpenRouter LLMs.

⸻

Product Requirements Document (PRD)
Product Name: WhisperNote (working title)
Platform: macOS
Owner: [Your Name]
Last Updated: 2025-05-06

⸻

1. Purpose

WhisperNote is a native macOS app that allows users to record meetings in real-time—capturing both microphone and system (computer) audio—without requiring bots or meeting invites. After recording, it transcribes the audio using ElevenLabs’ Speech-to-Text API and allows the user to generate a summary using a language model of their choice via OpenRouter.

⸻

2. Goals and Non-Goals

Goals:
	•	Enable seamless audio recording of meetings (both mic and system audio).
	•	Transcribe recorded audio via ElevenLabs Speech-to-Text API.
	•	Summarize the transcription using LLMs accessed via OpenRouter.
	•	Provide a clean, simple UI for recording, transcription, and summarization.

Non-Goals:
	•	Live transcription (real-time display of text while speaking).
	•	Direct calendar integration or meeting detection.
	•	Support for platforms other than macOS in the initial version.

⸻

3. Features

3.1 Audio Recording
	•	✅ Capture microphone audio.
	•	✅ Capture system (computer) audio.
	•	✅ Save recording as .wav or .mp3 format.
	•	✅ Simple UI to Start, Pause, Stop, Save recordings.
	•	✅ Auto-save fallback in case of crash or shutdown.

3.2 Transcription (ElevenLabs API)
	•	Upload saved audio file to ElevenLabs API (per API Reference).
	•	Show progress indicator during transcription.
	•	Display full transcript after completion.
	•	Store transcripts locally and allow export as .txt.

3.3 Summarization (OpenRouter + LLMs)
	•	Allow users to select a preferred LLM (e.g., GPT-4, Claude, Mistral) via OpenRouter.
	•	Send full transcript as prompt to generate a meeting summary.
	•	Show summary in a separate section with export to .txt or .md.
	•	Option to regenerate or fine-tune summary prompt.

3.4 UI/UX
	•	Native macOS interface with SwiftUI or AppKit.
	•	Multi-tab or sectioned view:
	•	Recordings
	•	Transcripts
	•	Summaries
	•	User preferences/settings:
	•	Default LLM model
	•	API keys for ElevenLabs and OpenRouter
	•	Audio format and recording quality

⸻

4. User Stories

As a user:
	•	I want to record both my mic and the meeting audio without needing to add a bot.
	•	I want the app to transcribe the audio automatically after the meeting ends.
	•	I want to choose from multiple LLMs to generate accurate and structured meeting summaries.
	•	I want a clean UI where I can view my recordings, transcripts, and summaries in one place.

⸻

5. Technical Requirements

5.1 macOS Recording
	•	Use AVFoundation or AudioKit for capturing mic and system audio.
	•	May require installation of a virtual audio driver (e.g., BlackHole or Loopback) for system audio capture.

5.2 ElevenLabs Integration
	•	Send POST request to:

POST https://api.elevenlabs.io/v1/speech-to-text/convert
Headers:
  "xi-api-key": YOUR_API_KEY
Body:
  multipart/form-data
  - file: audio file (.wav/.mp3)


	•	Handle response and extract transcript.

5.3 OpenRouter Integration
	•	Send prompt (the transcript) to OpenRouter endpoint.
	•	Allow user to input OpenRouter API key.
	•	Format prompt for LLM to summarize meeting (e.g., extract action items, attendees, agenda).

5.4 Data Storage
	•	Store audio, transcripts, summaries in user’s Library directory.
	•	Optional: allow cloud sync (e.g., iCloud) in future versions.

⸻

6. Security and Privacy
	•	All recordings and transcriptions are stored locally unless the user chooses to upload.
	•	API keys stored securely using macOS Keychain.
	•	Clear disclaimer for users about recording permissions and compliance (esp. for system audio).

⸻

7. Metrics for Success
	•	Time to transcription completion.
	•	Accuracy/quality of summaries.
	•	User retention and daily active users.
	•	Crash rate during recording and API calls.

⸻

8. Future Enhancements
	•	Live transcription.
	•	Calendar integration and automatic meeting detection.
	•	iOS companion app.
	•	Keyword/topic tagging.
	•	Team/collaboration features.

⸻
