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

    /// Set to true by `cancel()` right before we `terminate()` the running process, so the
    /// completion handler can distinguish a user-requested cancel from a real crash.
    private var didRequestCancel = false
    /// Reference to the in-flight whisper-cli process so `cancel()` can terminate it.
    private var currentProcess: Process?

    /// Cancel the in-flight transcription (terminates the running whisper-cli process).
    func cancel() {
        didRequestCancel = true
        currentProcess?.terminate()
    }

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

    /// Default thread count when the caller doesn't pass an explicit `threads` value.
    /// On Apple Silicon, prefer the number of *performance* cores — including the energy
    /// efficiency cores is counterproductive for whisper. Falls back to the previous
    /// `cores - 1` heuristic when the perf-core query is unavailable (e.g. Intel) or returns 0.
    static func defaultThreadCount() -> Int {
        var perfCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &perfCores, &size, nil, 0) == 0, perfCores > 0 {
            return Int(perfCores)
        }
        return max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
    }

    /// Run whisper-cli on the given file. Returns the spawned `Process` so the caller can
    /// `terminate()` it on cancel; nil if the process never started.
    /// - Parameters:
    ///   - threads: number of threads for whisper-cli (`-t`). nil → performance-core count (Apple Silicon), else cores - 1.
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

        // Reset cancel state for this run.
        didRequestCancel = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.qualityOfService = qos
        currentProcess = process

        let chosenThreads = threads ?? Self.defaultThreadCount()
        var args = [
            "-m", modelPath,
            "-f", audioFileURL.path,
            "-l", language,
            "-t", String(chosenThreads),
            "-fa",          // flash attention (faster + less memory on Metal)
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

                let didCancel = self.didRequestCancel
                self.currentProcess = nil

                if process.terminationStatus != 0 {
                    print("mywisper: whisper-cli failed with status \(process.terminationStatus)")
                    print("mywisper: stderr: \(errorOutput.prefix(200))")
                    DispatchQueue.main.async {
                        // Only treat a signal-termination as cancellation when WE asked for it.
                        // Otherwise an uncaughtSignal is a real crash (missing dylib, bad model,
                        // out of memory, …) and we surface the underlying reason from stderr.
                        if didCancel {
                            completion(.failure(WhisperTranscriberError.cancelled))
                        } else {
                            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
                            completion(.failure(WhisperTranscriberError.transcriptionFailed(detail: String(detail))))
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
                    // An empty cleaned result means whisper only produced artifacts like
                    // [BLANK_AUDIO]; surface this distinctly so the caller can show
                    // "No speech detected" instead of silently pasting nothing.
                    if cleaned.isEmpty {
                        completion(.failure(WhisperTranscriberError.noSpeechDetected))
                    } else {
                        completion(.success(cleaned))
                    }
                }
            } catch {
                print("mywisper: Failed to launch whisper-cli: \(error)")
                errorPipe.fileHandleForReading.readabilityHandler = nil
                self.currentProcess = nil
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
    case transcriptionFailed(detail: String)
    case noSpeechDetected
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded. Select a model in Settings."
        case .binaryNotFound:
            return "whisper-cli binary not found. Build whisper.cpp first."
        case .audioLoadFailed:
            return "Failed to load audio file for Whisper."
        case .transcriptionFailed(let detail):
            if detail.isEmpty {
                return "Whisper transcription failed."
            }
            return "Whisper transcription failed: \(detail)"
        case .noSpeechDetected:
            return "No speech detected."
        case .cancelled:
            return "Transcription cancelled."
        }
    }
}
