//
//  ModelDownloader.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation

struct WhisperModel: Identifiable {
    let id: String          // e.g. "ggml-tiny"
    let name: String        // e.g. "Tiny"
    let fileName: String    // e.g. "ggml-tiny.bin"
    let size: String        // e.g. "75 MB"
    let quality: String     // e.g. "Basic"
    let url: String

    static let all: [WhisperModel] = [
        WhisperModel(
            id: "ggml-tiny", name: "Tiny", fileName: "ggml-tiny.bin",
            size: "75 MB", quality: "Basic",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
        ),
        WhisperModel(
            id: "ggml-tiny.en", name: "Tiny (English)", fileName: "ggml-tiny.en.bin",
            size: "75 MB", quality: "Basic, English only",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
        ),
        WhisperModel(
            id: "ggml-base", name: "Base", fileName: "ggml-base.bin",
            size: "142 MB", quality: "Good",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        ),
        WhisperModel(
            id: "ggml-base.en", name: "Base (English)", fileName: "ggml-base.en.bin",
            size: "142 MB", quality: "Good, English only",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
        ),
        WhisperModel(
            id: "ggml-small", name: "Small", fileName: "ggml-small.bin",
            size: "466 MB", quality: "Better",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
        ),
        WhisperModel(
            id: "ggml-small.en", name: "Small (English)", fileName: "ggml-small.en.bin",
            size: "466 MB", quality: "Better, English only",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
        ),
        WhisperModel(
            id: "ggml-medium", name: "Medium", fileName: "ggml-medium.bin",
            size: "1.5 GB", quality: "Great",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
        ),
        WhisperModel(
            id: "ggml-medium.en", name: "Medium (English)", fileName: "ggml-medium.en.bin",
            size: "1.5 GB", quality: "Great, English only",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin"
        ),
        WhisperModel(
            id: "ggml-large-v3", name: "Large v3", fileName: "ggml-large-v3.bin",
            size: "3.1 GB", quality: "Best",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
        ),
    ]
}

class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var downloadingModelId: String?
    @Published var downloadProgress: Double = 0
    @Published var errorMessage: String?

    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("mywisper/models", isDirectory: true)
    }

    init() {
        copyBundledModelIfNeeded()
    }

    func modelPath(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }

    /// Copy model from app bundle Resources to Application Support (first launch)
    private func copyBundledModelIfNeeded() {
        let tinyPath = modelsDirectory.appendingPathComponent("ggml-tiny.bin")
        guard !FileManager.default.fileExists(atPath: tinyPath.path) else { return }
        guard let bundledURL = Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin") else { return }

        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        do {
            try FileManager.default.copyItem(at: bundledURL, to: tinyPath)
            print("mywisper: Copied bundled model to \(tinyPath.path)")
        } catch {
            print("mywisper: Failed to copy bundled model: \(error.localizedDescription)")
        }
    }

    func downloadModel(_ model: WhisperModel, completion: (() -> Void)? = nil) {
        guard downloadingModelId == nil else { return }

        downloadingModelId = model.id
        downloadProgress = 0
        errorMessage = nil

        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        guard let url = URL(string: model.url) else {
            errorMessage = "Invalid model URL"
            downloadingModelId = nil
            return
        }

        let destPath = modelPath(for: model)

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        let task = session.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.downloadingModelId = nil

                if let error = error {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    return
                }

                guard let tempURL = tempURL else {
                    self.errorMessage = "Download failed: no file received"
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: destPath.path) {
                        try FileManager.default.removeItem(at: destPath)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destPath)
                    print("mywisper: Downloaded \(model.fileName) to \(destPath.path)")
                    completion?()
                } catch {
                    self.errorMessage = "Failed to save model: \(error.localizedDescription)"
                }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        task.resume()
    }

    func deleteModel(_ model: WhisperModel) {
        let path = modelPath(for: model)
        try? FileManager.default.removeItem(at: path)
    }
}
