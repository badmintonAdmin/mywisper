# mywisper

A lightweight macOS menu bar dictation app. Record speech with a global hotkey, transcribe locally using [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and paste the result into any text field — no cloud APIs required.

Inspired by [Superwhisper](https://superwhisper.com) and [Wispr Flow](https://wispr.com).

![macOS](https://img.shields.io/badge/macOS-13.3%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Local transcription** — runs whisper.cpp on-device, no data leaves your Mac
- **Global hotkey** — double-tap Fn or customizable shortcut (default: ⌃⌥Space)
- **Menu bar native** — lives in the menu bar, no dock icon
- **Multiple Whisper models** — from Tiny (75 MB) to Large v3 (3.1 GB), downloadable in-app
- **AI post-processing** — optional OpenAI integration to clean up, translate, or restyle transcriptions
- **6 built-in AI presets** — Clean Up, Translate, Developer Style, Warm & Friendly, Formal Business
- **Three engines** — Cloud Whisper (OpenAI API, best quality), local whisper.cpp (private), or Apple Speech (fast, no model download)
- **Smart vocabulary** — add technical terms once, they're used as hints for both Whisper API and AI post-processing
- **Language support** — English and Russian
- **Auto-paste** — transcribed text is pasted directly into the focused app
- **Recording overlay** — floating pill with waveform, timer, and stop button
- **Transcription history** — browse and copy past transcriptions

## Installation

### From DMG

1. Download `mywisper.dmg` from [Releases](../../releases)
2. Open the DMG and drag **mywisper** to Applications
3. Launch mywisper — it appears in the menu bar (microphone icon)
4. Grant permissions when prompted (see [Permissions](#permissions))

### Build from Source

Requires Xcode 15+ with macOS 13.3+ SDK.

```bash
# Clone
git clone https://github.com/yourusername/mywisper.git
cd mywisper

# Build
xcodebuild -project mywisper.xcodeproj -scheme mywisper -configuration Release build
```

The built app will be at `~/Library/Developer/Xcode/DerivedData/mywisper-*/Build/Products/Release/mywisper.app`.

## Permissions

mywisper requires three macOS permissions:

| Permission | Why | How to grant |
|---|---|---|
| **Microphone** | Record audio | Prompted automatically on first recording |
| **Accessibility** | Simulate Cmd+V to paste text | System Settings → Privacy & Security → Accessibility → enable mywisper |
| **Fn key** (optional) | Double-tap Fn hotkey | System Settings → Keyboard → set "Fn key" to "Do Nothing" |

> **Note:** If Accessibility is not granted, mywisper will still copy transcriptions to the clipboard — you just need to paste manually with Cmd+V.

## Usage

1. Click the menu bar icon or press **double-tap Fn** (or **⌃⌥Space**) to start recording
2. Speak — the floating overlay shows a waveform and timer
3. Press the hotkey again (or click Stop) to finish
4. Transcribed text is automatically pasted into the focused text field

### AI Post-Processing

1. Open Settings → AI Processing
2. Enter your OpenAI API key
3. Enable AI processing and choose a preset or write a custom system prompt
4. Toggle AI on/off quickly with **⌃⌥A** hotkey

### Whisper Models

On first launch, the bundled Tiny model is ready to use. For better accuracy, download larger models from Settings → Whisper Model:

| Model | Size | Quality |
|---|---|---|
| Tiny / Tiny.en | 75 MB | Fast, basic accuracy |
| Base / Base.en | 142 MB | Good balance |
| Small / Small.en | 466 MB | Better accuracy |
| Medium / Medium.en | 1.5 GB | High accuracy |
| Large v3 | 3.1 GB | Best accuracy |

`.en` models are English-only but more accurate for English.

## Architecture

```
Hotkey (Fn double-tap / ⌃⌥Space)
  → DictationManager (orchestrator)
    ├── AudioRecorder — AVAudioRecorder, 16kHz mono PCM
    ├── WhisperTranscriber — whisper.cpp CLI transcription
    ├── CloudWhisperService — OpenAI Whisper API transcription
    ├── SpeechTranscriber — Apple Speech (alternative engine)
    ├── OpenAIService — optional AI post-processing
    ├── TextPaster — NSPasteboard + CGEvent Cmd+V
    ├── RecordingOverlay — floating NSPanel with waveform
    ├── ModelDownloader — HuggingFace model downloads
    ├── TranscriptionHistory — persistent JSON history
    └── SettingsManager — UserDefaults configuration
```

## Configuration

All settings are accessible from the menu bar → Settings:

- **Engine** — Cloud Whisper (OpenAI), local Whisper, or Apple Speech
- **Language** — English / Russian
- **Hotkeys** — double-tap Fn interval, custom hotkey, AI toggle hotkey
- **AI** — API key, model, system prompt, presets
- **Model** — select and download Whisper models

Settings are stored in `UserDefaults` and persist across launches.

## Tech Stack

- Swift 5 / SwiftUI
- whisper.cpp (bundled CLI binary)
- AVAudioRecorder for audio capture
- CGEvent for keystroke simulation
- NSPanel for floating overlay
- OpenAI Chat Completions API (optional)

## License

MIT
