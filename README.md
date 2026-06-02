# mywisper

A lightweight macOS menu bar dictation app. Record speech with a global hotkey, transcribe using whisper.cpp (local), OpenAI Whisper API (cloud), or Apple Speech, and paste the result into any text field automatically.

![macOS](https://img.shields.io/badge/macOS-13.3%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-green)

> **Latest release:** [v1.1.1](https://github.com/badmintonAdmin/mywisper/releases/tag/v1.1.1) — 2026-06-02
> - **Apple Silicon (M1/M2/M3/M4):** [download DMG](https://github.com/badmintonAdmin/mywisper/releases/download/v1.1.1/mywisper-1.1.1-AppleSilicon.dmg) · [`installation/Silicon/mywisper.dmg`](installation/Silicon/mywisper.dmg)
> - **Intel:** [v1.0.0 DMG](https://github.com/badmintonAdmin/mywisper/releases/download/v1.0.0/mywisper-1.0.0-Intel.dmg) (1.1 Intel build not yet published)

## Features

- **Three transcription engines** — Cloud Whisper (OpenAI API, best quality), local whisper.cpp (fully private), or Apple Speech (fast, no model download)
- **Global hotkey** — double-tap Fn or customizable shortcut (default: ⌃⌥Space)
- **Menu bar native** — lives in the menu bar with status icon, no dock icon
- **Multiple Whisper models** — 9 models from Tiny (75 MB) to Large v3 (3.1 GB), downloadable in-app
- **AI post-processing** — optional OpenAI integration to clean up, translate, or restyle transcriptions
- **6 built-in AI presets** — Clean Up, Translate to English/Russian, Developer Style, Warm & Friendly, Formal Business — plus custom presets
- **Smart vocabulary** — add technical terms once, they're used as hints for both Whisper API and AI post-processing
- **Custom dictionary** — manual word replacements (wrong → correct) applied automatically after transcription
- **Language support** — English and Russian, switchable from menu bar
- **Auto-paste** — transcribed text is pasted directly into the focused app via simulated Cmd+V
- **Recording overlay** — floating pill with real-time waveform, elapsed timer, and stop button
- **Transcription history** — searchable list with metadata, copy, and delete
- **Cloud upload safety net** — auto-retries on transient errors, persists audio on failure so a flaky network or OpenAI outage never costs you a long dictation
- **Transcribe any file** — drag & drop audio (WAV/MP3/M4A/AAC/FLAC/AIFF) or video (MP4/MOV) up to 60 minutes; runs entirely locally via your installed Whisper model and stays out of the way of live dictation

## Installation

### From DMG

1. Download the DMG that matches your Mac — or grab it from [mywhisper.cloud](https://mywhisper.cloud/):
   - **Apple Silicon (M1/M2/M3/M4):** [`installation/Silicon/mywisper.dmg`](installation/Silicon/mywisper.dmg)
   - **Intel:** [`installation/Intel/mywisper.dmg`](installation/Intel/mywisper.dmg)

   > Not sure which? Click  → About This Mac. "Apple M…" = Silicon; "Intel…" = Intel.
2. Open the DMG and drag **mywisper** to Applications
3. Launch mywisper — it appears in the menu bar (microphone icon)
4. Grant permissions when prompted (see [Permissions](#permissions))

### Build from Source

Requires Xcode 15+ with macOS 13.3+ SDK.

```bash
git clone https://github.com/yourusername/mywisper.git
cd mywisper

# Resolve dependencies (SwiftWhisper via SPM)
xcodebuild -project mywisper.xcodeproj -scheme mywisper -resolvePackageDependencies

# Build
xcodebuild -project mywisper.xcodeproj -scheme mywisper -configuration Release build
```

### Build DMG Installer

```bash
bash scripts/create_dmg.sh
```

Builds the app for Apple Silicon (arm64), compiles whisper.cpp natively (Metal-accelerated)
via `scripts/build_whisper.sh`, bundles `whisper-cli` **and all its dylibs** into the app so
the binary is fully self-contained (`scripts/bundle_whisper.sh` rewrites the load paths to
`@loader_path`), re-signs the bundle, and writes a styled DMG to `installation/Silicon/mywisper.dmg`.

Build for Intel instead with `ARCH=x86_64 bash scripts/create_dmg.sh` (requires an Intel-capable
whisper.cpp build). Override the signing identity with `CODESIGN_ID="Developer ID Application: …"`.

## Permissions

mywisper requires these macOS permissions:

| Permission            | Why                                 | How to grant                                                           |
| --------------------- | ----------------------------------- | ---------------------------------------------------------------------- |
| **Microphone**        | Record audio                        | Prompted automatically on first recording                              |
| **Accessibility**     | Global hotkeys + auto-paste (Cmd+V) | System Settings → Privacy & Security → Accessibility → enable mywisper |
| **Fn key** (optional) | Double-tap Fn hotkey                | System Settings → Keyboard → set "Fn key" to "Do Nothing"              |

> **Note:** Without Accessibility permission, you can still record via the menu bar and transcriptions are copied to the clipboard — you just need to paste manually with Cmd+V.

## Usage

### Basic Dictation

1. Press **double-tap Fn** or **⌃⌥Space** to start recording
2. Speak — the floating overlay shows a waveform and timer
3. Press the hotkey again (or click Stop on the overlay) to finish
4. Transcribed text is automatically pasted into the focused text field

### Transcription Engines

Choose your engine in Settings → General:

| Engine            | Quality | Privacy               | Requirements                    |
| ----------------- | ------- | --------------------- | ------------------------------- |
| **Cloud Whisper** | Best    | Sends audio to OpenAI | OpenAI API key                  |
| **Local Whisper** | Great   | Fully on-device       | whisper.cpp binary + model file |
| **Apple Speech**  | Good    | On-device             | None (uses macOS built-in)      |

### AI Post-Processing

After transcription, mywisper can optionally send the text through an AI model to improve it:

1. Open Settings → AI Processing
2. Enter your OpenAI API key
3. Enable AI processing and choose a preset or write a custom system prompt
4. Toggle AI on/off quickly with the **AI toggle hotkey** (configurable in Settings → Hotkey)

**Built-in presets:**

| Preset               | What it does                                      |
| -------------------- | ------------------------------------------------- |
| Clean Up             | Fix grammar, punctuation, formatting              |
| Translate to English | Translate from any language to English            |
| Translate to Russian | Translate from any language to Russian            |
| Developer Style      | Format for code comments, commits, technical docs |
| Warm & Friendly      | Conversational, approachable tone                 |
| Formal Business      | Professional emails and documents                 |

You can create, edit, and delete custom presets. If AI processing fails, the raw transcription is used as a fallback.

**Supported AI models:** gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-3.5-turbo.

### Smart Vocabulary & Dictionary

**Vocabulary terms** — add technical words (e.g., "Kubernetes", "nginx", "Dokploy") that are often misheard:

- In Cloud Whisper mode: sent as hints to the Whisper API
- In AI mode: included in the system prompt so AI corrects mangled variants
- Works with any engine when AI processing is enabled

**Manual replacements** — define exact substitutions (e.g., "dogploy" → "Dokploy"):

- Case-insensitive find-and-replace
- Applied after transcription, works with all engines
- No AI required

### Whisper Models

On first launch, the bundled Tiny model is ready to use. Download larger models from Settings → General → Whisper Model:

| Model              | Size   | Quality              |
| ------------------ | ------ | -------------------- |
| Tiny / Tiny.en     | 75 MB  | Fast, basic accuracy |
| Base / Base.en     | 142 MB | Good balance         |
| Small / Small.en   | 466 MB | Better accuracy      |
| Medium / Medium.en | 1.5 GB | High accuracy        |
| Large v3           | 3.1 GB | Best accuracy        |

`.en` models are English-only but more accurate for English speech.

Models are downloaded from HuggingFace and stored in `~/Library/Application Support/mywisper/models/`. The app also auto-discovers models from SuperWhisper's directory and `~/Downloads/whisper.cpp/models/`.

### Hotkeys

| Hotkey               | Default               | Description                      |
| -------------------- | --------------------- | -------------------------------- |
| **Recording toggle** | ⌃⌥Space               | Start/stop recording             |
| **Double-tap Fn**    | Enabled (0.4s window) | Alternative recording trigger    |
| **AI toggle**        | Disabled              | Toggle AI post-processing on/off |

All hotkeys are configurable in Settings → Hotkey. Custom hotkeys require at least one modifier key (Ctrl, Option, Shift, or Cmd).

### Transcription History

Access history from the menu bar → History. Each entry shows:

- Transcribed text (expandable)
- Original/raw text toggle (for AI-processed entries)
- Metadata: timestamp, engine, duration, language, AI model
- Copy and delete buttons

History is searchable and stored in `~/Library/Application Support/mywisper/history.json`.

### Cloud Transcription Reliability

When using the Cloud (OpenAI) engine, mywisper protects long dictations from network glitches and API outages so you never have to redictate.

**How it works:**

1. **Save before sending.** As soon as you stop recording, the audio is copied to `~/Library/Application Support/mywisper/pending/{uuid}.wav` *before* the upload begins. If the app or laptop crashes mid-upload, the audio survives.
2. **Auto-retry on transient errors.** Network timeouts, lost connections, DNS hiccups, OpenAI 5xx, and rate limits (429) trigger up to 2 silent retries (~2s, then ~5s backoff) — the recording overlay shows `Retrying 2/3...` so you know what's happening.
3. **Persist on final failure.** If retries are exhausted (or the error is permanent, like a bad API key), the audio stays on disk and a macOS notification fires with a **Retry** action button.
4. **Recover anytime.** A "Pending uploads" section appears in the menu bar dropdown and in Settings → General. Each row has Retry / Discard buttons. On app start the list is rehydrated from disk, so a crash recovery is just one click.
5. **Auto-cleanup.** Successful retries delete the pending files. Anything older than 30 days is purged on startup.

**What doesn't trigger retries:** authentication failures (401) and other 4xx errors — those would just fail again, so the audio is saved straight to pending for manual investigation.

**Cancel any time.** Hitting your Cancel hotkey during a retry aborts and discards the pending audio (so cancellation always cleans up after itself).

**Files:** `~/Library/Application Support/mywisper/pending/` — pairs of `{uuid}.wav` (audio) and `{uuid}.json` (metadata: language, prompt, last error, retry count).

### Transcribe a File

For one-off transcription of a recording you didn't make through mywisper — a podcast episode, an interview, the audio track of a screencast — open **Transcribe File...** from the menu bar (default `⌘T` while the menu is open).

**Supported formats:**

| Type  | Extensions                                  |
| ----- | ------------------------------------------- |
| Audio | WAV, MP3, M4A, AAC, FLAC, AIFF              |
| Video | MP4, MOV, M4V (audio track is extracted)    |

Files up to **60 minutes** are accepted; longer files are rejected up front so you don't wait on something that won't fit. Drop a file into the window or click to browse, then hit **Transcribe**. While the run is in progress you can:

- **Close the window** — the work continues in the background. The menu bar shows `📄 podcast.mp3 — 47%` while it runs and posts a "Transcription ready" notification with a **Show** action when it finishes.
- **Keep dictating** — the file run uses lower CPU priority (`.utility` QoS) and only half the cores, so live dictation through your hotkey stays responsive.
- **Cancel** — kills the background process immediately and cleans up the temp file.

The result view shows the full text with **Copy** and **Save as .txt** actions. Everything runs locally through your installed Whisper model (`Settings → General → Whisper Model`) — no audio is sent to any cloud service in this flow.

### Menu Bar

The menu bar dropdown provides quick access to:

- **Status** — Ready / Recording / Transcribing (icon changes accordingly)
- **Last transcription** — click to copy
- **Start/Stop recording** — with hotkey hint
- **Language** — switch between English and Russian
- **Engine** — current engine display
- **AI toggle** — enable/disable with preset selector
- **Pending uploads** — failed cloud transcriptions awaiting retry (shown only when non-empty)
- **Background file transcription** — `📄 filename.mp3 — N%` (shown only while a file is being transcribed)
- **Transcribe File...** — open the file-transcription window
- **History** — open history viewer (shows entry count)
- **Settings** — open settings window

## Architecture

```
Hotkey (Fn double-tap / ⌃⌥Space)
  → DictationManager (orchestrator)
    ├── AudioRecorder — AVAudioRecorder, 16kHz mono PCM + real-time metering
    ├── WhisperTranscriber — whisper.cpp CLI transcription (local)
    ├── CloudWhisperService — OpenAI Whisper API + transient/permanent error classifier
    ├── SpeechTranscriber — Apple Speech framework (local)
    ├── OpenAIService — AI post-processing via Chat Completions API
    ├── TextPaster — NSPasteboard + CGEvent Cmd+V simulation
    ├── RecordingOverlay — floating NSPanel with waveform + timer
    ├── HotkeyManager — CGEventTap + NSEvent monitoring
    ├── ModelDownloader — HuggingFace model downloads with progress
    ├── TranscriptionHistory — persistent JSON history
    ├── PendingRecordingsStore — on-disk safety net for failed cloud uploads
    ├── NotificationManager — macOS notifications with Retry / Show actions
    └── SettingsManager — UserDefaults configuration

FileTranscriptionService.shared (independent)
  ├── AudioExtractor — AVAssetReader/Writer, any audio or video → 16 kHz mono WAV
  └── WhisperTranscriber — same engine as live dictation, but runs at .utility QoS
        and uses half the cores so it doesn't fight live dictation for CPU
```

**Cloud transcription flow with reliability layer:** Stop recording → copy audio to `pending/{uuid}.wav` → upload → on transient error (timeout / no internet / 5xx / 429) auto-retry up to 3 times with backoff → on success delete from pending → on final failure mark in store + post system notification with Retry action. App startup rehydrates the pending list from disk, so a crash mid-upload becomes a one-click recovery.

**Standard flow:** Hotkey → start recording → stop → transcribe (engine-dependent) → optional AI processing → optional dictionary replacements → copy to clipboard → simulate Cmd+V paste → save to history.

## Settings

All settings are accessible from the menu bar → Settings, organized in three tabs:

### General

- **Pending uploads** — list of failed cloud transcriptions with Retry / Discard (shown only when non-empty)
- Transcription engine selection (Apple / Whisper / Cloud)
- Whisper model management (download, select, browse)
- whisper-cli binary path
- Language (English / Russian)

### AI Processing

- Enable/disable AI processing
- OpenAI API key and model selection
- System prompt editor with preset management
- Custom dictionary: vocabulary terms + manual replacements

### Hotkey

- Custom recording hotkey configuration
- Double-tap Fn toggle and speed adjustment (0.2–0.8s)
- AI toggle hotkey configuration
- Accessibility permission status and setup instructions

## Tech Stack

- Swift 5 / SwiftUI
- whisper.cpp (CLI binary for local transcription)
- SwiftWhisper (SPM dependency)
- AVAudioRecorder for audio capture
- CGEvent for keystroke simulation (Cmd+V paste)
- NSPanel for floating recording overlay
- OpenAI Whisper API (cloud transcription)
- OpenAI Chat Completions API (AI post-processing)

## License

MIT
