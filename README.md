# mywisper

A lightweight macOS menu bar dictation app. Record speech with a global hotkey, transcribe using whisper.cpp (local), OpenAI Whisper API (cloud), or Apple Speech, and paste the result into any text field automatically.

Inspired by [Superwhisper](https://superwhisper.com) and [Wispr Flow](https://wispr.com).

![macOS](https://img.shields.io/badge/macOS-13.3%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-green)

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

## Installation

### From DMG

1. Download `mywisper.dmg` from [mywhisper.cloud](https://mywhisper.cloud/)
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

Creates a styled DMG at `~/Downloads/mywisper.dmg` with drag-to-Applications layout.

## Permissions

mywisper requires these macOS permissions:

| Permission | Why | How to grant |
|---|---|---|
| **Microphone** | Record audio | Prompted automatically on first recording |
| **Accessibility** | Global hotkeys + auto-paste (Cmd+V) | System Settings → Privacy & Security → Accessibility → enable mywisper |
| **Fn key** (optional) | Double-tap Fn hotkey | System Settings → Keyboard → set "Fn key" to "Do Nothing" |

> **Note:** Without Accessibility permission, you can still record via the menu bar and transcriptions are copied to the clipboard — you just need to paste manually with Cmd+V.

## Usage

### Basic Dictation

1. Press **double-tap Fn** or **⌃⌥Space** to start recording
2. Speak — the floating overlay shows a waveform and timer
3. Press the hotkey again (or click Stop on the overlay) to finish
4. Transcribed text is automatically pasted into the focused text field

### Transcription Engines

Choose your engine in Settings → General:

| Engine | Quality | Privacy | Requirements |
|---|---|---|---|
| **Cloud Whisper** | Best | Sends audio to OpenAI | OpenAI API key |
| **Local Whisper** | Great | Fully on-device | whisper.cpp binary + model file |
| **Apple Speech** | Good | On-device | None (uses macOS built-in) |

### AI Post-Processing

After transcription, mywisper can optionally send the text through an AI model to improve it:

1. Open Settings → AI Processing
2. Enter your OpenAI API key
3. Enable AI processing and choose a preset or write a custom system prompt
4. Toggle AI on/off quickly with the **AI toggle hotkey** (configurable in Settings → Hotkey)

**Built-in presets:**

| Preset | What it does |
|---|---|
| Clean Up | Fix grammar, punctuation, formatting |
| Translate to English | Translate from any language to English |
| Translate to Russian | Translate from any language to Russian |
| Developer Style | Format for code comments, commits, technical docs |
| Warm & Friendly | Conversational, approachable tone |
| Formal Business | Professional emails and documents |

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

| Model | Size | Quality |
|---|---|---|
| Tiny / Tiny.en | 75 MB | Fast, basic accuracy |
| Base / Base.en | 142 MB | Good balance |
| Small / Small.en | 466 MB | Better accuracy |
| Medium / Medium.en | 1.5 GB | High accuracy |
| Large v3 | 3.1 GB | Best accuracy |

`.en` models are English-only but more accurate for English speech.

Models are downloaded from HuggingFace and stored in `~/Library/Application Support/mywisper/models/`. The app also auto-discovers models from SuperWhisper's directory and `~/Downloads/whisper.cpp/models/`.

### Hotkeys

| Hotkey | Default | Description |
|---|---|---|
| **Recording toggle** | ⌃⌥Space | Start/stop recording |
| **Double-tap Fn** | Enabled (0.4s window) | Alternative recording trigger |
| **AI toggle** | Disabled | Toggle AI post-processing on/off |

All hotkeys are configurable in Settings → Hotkey. Custom hotkeys require at least one modifier key (Ctrl, Option, Shift, or Cmd).

### Transcription History

Access history from the menu bar → History. Each entry shows:
- Transcribed text (expandable)
- Original/raw text toggle (for AI-processed entries)
- Metadata: timestamp, engine, duration, language, AI model
- Copy and delete buttons

History is searchable and stored in `~/Library/Application Support/mywisper/history.json`.

### Menu Bar

The menu bar dropdown provides quick access to:
- **Status** — Ready / Recording / Transcribing (icon changes accordingly)
- **Last transcription** — click to copy
- **Start/Stop recording** — with hotkey hint
- **Language** — switch between English and Russian
- **Engine** — current engine display
- **AI toggle** — enable/disable with preset selector
- **History** — open history viewer (shows entry count)
- **Settings** — open settings window

## Architecture

```
Hotkey (Fn double-tap / ⌃⌥Space)
  → DictationManager (orchestrator)
    ├── AudioRecorder — AVAudioRecorder, 16kHz mono PCM + real-time metering
    ├── WhisperTranscriber — whisper.cpp CLI transcription (local)
    ├── CloudWhisperService — OpenAI Whisper API transcription (cloud)
    ├── SpeechTranscriber — Apple Speech framework (local)
    ├── OpenAIService — AI post-processing via Chat Completions API
    ├── TextPaster — NSPasteboard + CGEvent Cmd+V simulation
    ├── RecordingOverlay — floating NSPanel with waveform + timer
    ├── HotkeyManager — CGEventTap + NSEvent monitoring
    ├── ModelDownloader — HuggingFace model downloads with progress
    ├── TranscriptionHistory — persistent JSON history
    └── SettingsManager — UserDefaults configuration
```

**Flow:** Hotkey → start recording → stop → transcribe (engine-dependent) → optional AI processing → optional dictionary replacements → copy to clipboard → simulate Cmd+V paste → save to history.

## Settings

All settings are accessible from the menu bar → Settings, organized in three tabs:

### General
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
