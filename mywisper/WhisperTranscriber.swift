//
//  WhisperTranscriber.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation

class WhisperTranscriber {
    private var modelPath: String?
    private var language: String = "en"

    /// Path to the whisper.cpp CLI binary (whisper-cli)
    var binaryPath: String {
        get {
            // Check user override first
            if let stored = UserDefaults.standard.string(forKey: "whisperBinaryPath"),
               FileManager.default.fileExists(atPath: stored) {
                return stored
            }
            // Check bundled binary
            if let bundled = bundledBinaryPath,
               FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
            return UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? defaultBinaryPath
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "whisperBinaryPath")
        }
    }

    private var bundledBinaryPath: String? {
        Bundle.main.path(forResource: "whisper-cli", ofType: nil)
    }

    private var defaultBinaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Downloads/whisper.cpp/build/bin/whisper-cli"
    }

    var isReady: Bool {
        guard let path = modelPath, !path.isEmpty else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: path) && fm.fileExists(atPath: binaryPath)
    }

    func loadModel(path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            print("mywisper: Whisper model not found at \(path)")
            modelPath = nil
            return
        }
        modelPath = path

        if !FileManager.default.fileExists(atPath: binaryPath) {
            print("mywisper: WARNING - whisper-cli binary not found at \(binaryPath)")
            print("mywisper: Build whisper.cpp first: cd ~/Downloads/whisper.cpp && make")
        }
    }

    func setLanguage(_ language: String) {
        if language.starts(with: "ru") {
            self.language = "ru"
        } else {
            self.language = "en"
        }
    }

    func transcribe(audioFileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        _ = transcribe(audioFileURL: audioFileURL, threads: nil, qos: .userInitiated, onProgress: nil, completion: completion)
    }

    /// Run whisper-cli on the given file. Returns the spawned `Process` so the caller can
    /// `terminate()` it on cancel; nil if the process never started.
    /// - Parameters:
    ///   - threads: number of threads for whisper-cli (`-t`). nil → cores - 1.
    ///   - qos: process priority. Use `.utility` for background work to spare the foreground dictation path.
    ///   - onProgress: 0...1 callback fired on the main queue while whisper-cli prints progress.
    @discardableResult
    func transcribe(
        audioFileURL: URL,
        threads: Int? = nil,
        qos: QualityOfService = .userInitiated,
        onProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> Process? {
        guard let modelPath = modelPath else {
            completion(.failure(WhisperTranscriberError.modelNotLoaded))
            return nil
        }

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            completion(.failure(WhisperTranscriberError.binaryNotFound))
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.qualityOfService = qos

        let chosenThreads = threads ?? max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
        var args = [
            "-m", modelPath,
            "-f", audioFileURL.path,
            "-l", language,
            "-t", String(chosenThreads),
            "-nt",          // no timestamps
        ]
        if onProgress != nil {
            args.append("--print-progress")
        } else {
            args.append("--no-prints")
        }
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Stream stderr line-by-line to capture whisper-cli's "progress = N%" lines.
        if let onProgress = onProgress {
            let progressRegex = try? NSRegularExpression(pattern: #"progress\s*=\s*(\d{1,3})%"#)
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) else { return }
                guard let regex = progressRegex else { return }
                let range = NSRange(str.startIndex..., in: str)
                regex.enumerateMatches(in: str, range: range) { match, _, _ in
                    guard let match = match,
                          let pctRange = Range(match.range(at: 1), in: str),
                          let pct = Double(str[pctRange]) else { return }
                    let normalized = max(0, min(1, pct / 100.0))
                    DispatchQueue.main.async { onProgress(normalized) }
                }
            }
        }

        // We must accumulate stdout off the main thread so a long transcription doesn't block UI.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()

                // Stop streaming progress before reading remaining buffers.
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    print("mywisper: whisper-cli failed with status \(process.terminationStatus)")
                    print("mywisper: stderr: \(errorOutput.prefix(200))")
                    DispatchQueue.main.async {
                        // Treat SIGTERM (15) / SIGKILL (9) as cancellation rather than a generic failure.
                        if process.terminationReason == .uncaughtSignal {
                            completion(.failure(WhisperTranscriberError.cancelled))
                        } else {
                            completion(.failure(WhisperTranscriberError.transcriptionFailed))
                        }
                    }
                    return
                }

                // Clean up whisper artifacts (e.g. "[BLANK_AUDIO]" tags)
                let cleaned = output
                    .replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    onProgress?(1.0)
                    completion(.success(cleaned))
                }
            } catch {
                print("mywisper: Failed to launch whisper-cli: \(error)")
                errorPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }

        return process
    }
}

enum WhisperTranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case binaryNotFound
    case audioLoadFailed
    case transcriptionFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded. Select a model in Settings."
        case .binaryNotFound:
            return "whisper-cli binary not found. Build whisper.cpp first."
        case .audioLoadFailed:
            return "Failed to load audio file for Whisper."
        case .transcriptionFailed:
            return "Whisper transcription failed."
        case .cancelled:
            return "Transcription cancelled."
        }
    }
}
