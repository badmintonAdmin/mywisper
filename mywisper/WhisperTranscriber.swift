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

        if FileManager.default.fileExists(atPath: binaryPath) {
            print("mywisper: Whisper CLI ready at \(binaryPath)")
            print("mywisper: Model: \(path)")
        } else {
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
        guard let modelPath = modelPath else {
            completion(.failure(WhisperTranscriberError.modelNotLoaded))
            return
        }

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            completion(.failure(WhisperTranscriberError.binaryNotFound))
            return
        }

        print("mywisper: Starting whisper-cli transcription...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.binaryPath)

            let threads = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
            process.arguments = [
                "-m", modelPath,
                "-f", audioFileURL.path,
                "-l", self.language,
                "-t", String(threads),
                "-nt",          // no timestamps
                "--no-prints",  // suppress progress output
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    print("mywisper: whisper-cli failed with status \(process.terminationStatus)")
                    print("mywisper: stderr: \(errorOutput.prefix(200))")
                    DispatchQueue.main.async {
                        completion(.failure(WhisperTranscriberError.transcriptionFailed))
                    }
                    return
                }

                // Clean up whisper artifacts
                let cleaned = output
                    .replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                print("mywisper: whisper-cli result: '\(cleaned.prefix(80))'")

                DispatchQueue.main.async {
                    completion(.success(cleaned))
                }
            } catch {
                print("mywisper: Failed to launch whisper-cli: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

enum WhisperTranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case binaryNotFound
    case audioLoadFailed
    case transcriptionFailed

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
        }
    }
}
