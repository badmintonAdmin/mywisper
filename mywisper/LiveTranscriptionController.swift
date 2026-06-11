//
//  LiveTranscriptionController.swift
//  mywisper
//
//  Drives live (segmented) Whisper transcription. It owns a StreamingAudioRecorder that emits
//  fixed-length WAV segments while the user is still speaking, and a dedicated WhisperTranscriber
//  that transcribes those segments one at a time, off the critical path. When the user stops, only
//  the unfinished tail remains — so a 10-minute dictation returns its text almost immediately
//  instead of after a full end-of-recording Whisper pass.
//
//  All mutable state is touched on the main queue only: the recorder delivers its callbacks on
//  main, and WhisperTranscriber delivers its completion on main, so no extra locking is needed.
//

import Foundation
import os

final class LiveTranscriptionController {
    private let recorder = StreamingAudioRecorder()
    private let whisper = WhisperTranscriber()

    /// Unified-logging channel so live progress is visible via Console.app / `log stream`
    /// (plain `print()` from a Finder-launched app is NOT captured anywhere).
    /// View with: `log stream --predicate 'subsystem == "com.barssoft.mywisper"' --info`
    private let log = Logger(subsystem: "com.barssoft.mywisper", category: "live")

    /// Forwarded microphone level for the overlay meter.
    var onAudioLevel: ((Float) -> Void)?

    /// Fired on the main queue each time a segment finishes transcribing, with the running count
    /// of completed segments — drives the "⚡N" badge in the recording overlay.
    var onSegmentCompleted: ((Int) -> Void)?

    /// True when the recording stopped under the minimum-duration threshold (accidental tap),
    /// mirroring AudioRecorder.lastRecordingWasTooShort so the caller can react the same way.
    private(set) var lastRecordingWasTooShort = false

    // Ordered segment results, keyed by segment index. Indices missing a key errored with no text.
    private var results: [Int: String] = [:]
    private var pending: [(index: Int, url: URL)] = []
    private var isWorking = false
    private var processedCount = 0

    private var totalSegments: Int?          // known only after stop()
    private var completion: ((Result<String, Error>) -> Void)?
    private var lastRealError: Error?
    private var cancelled = false
    /// Set once the user stops: from here on the user is actively waiting, so the remaining
    /// (tail) segments run at high priority instead of the background `.utility` used while
    /// recording was still in progress.
    private var flushing = false

    /// Begin a live recording session. Throws if the recorder can't start (mic/format issue).
    func start(language: String, modelPath: String, segmentSeconds: Double) throws {
        results.removeAll()
        pending.removeAll()
        isWorking = false
        processedCount = 0
        totalSegments = nil
        completion = nil
        lastRealError = nil
        cancelled = false
        flushing = false
        lastRecordingWasTooShort = false

        whisper.loadModel(path: modelPath)
        whisper.setLanguage(language)

        recorder.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
        recorder.onSegmentReady = { [weak self] url, index in
            self?.enqueue(url: url, index: index)
        }
        recorder.onFinished = { [weak self] total, _, tooShort in
            guard let self = self, !self.cancelled else { return }
            self.totalSegments = total
            self.lastRecordingWasTooShort = tooShort
            self.tryComplete()
        }

        try recorder.start(segmentSeconds: segmentSeconds)
    }

    /// Stop recording and deliver the combined transcript once every segment has been processed.
    /// The completion fires on the main queue.
    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        flushing = true   // user is now waiting — bump remaining segments to high priority
        recorder.stop()   // flushes the tail segment, then fires onFinished
    }

    /// Abort the session: stop recording, terminate any in-flight Whisper process, drop callbacks.
    func cancel() {
        cancelled = true
        completion = nil
        whisper.cancel()
        recorder.cancel()
        pending.removeAll()
    }

    // MARK: - Segment queue

    private func enqueue(url: URL, index: Int) {
        guard !cancelled else { return }
        log.info("segment \(index) ready (\(self.flushing ? "tail" : "during recording")) — \(self.pending.count + (self.isWorking ? 1 : 0)) queued")
        pending.append((index, url))
        pump()
    }

    private func pump() {
        guard !cancelled, !isWorking, let next = pending.first else { return }
        pending.removeFirst()
        isWorking = true

        // While still recording, run segments at background (utility) priority so they don't
        // starve the realtime audio thread. After the user stops (`flushing`), they're actively
        // waiting on the remaining tail, so run it at user-initiated priority for minimal latency.
        let qos: QualityOfService = flushing ? .userInitiated : .utility
        let started = Date()
        log.info("transcribing segment \(next.index) [\(qos == .userInitiated ? "high" : "bg")]")
        whisper.transcribe(
            audioFileURL: next.url,
            threads: nil,
            qos: qos,
            onProgress: nil
        ) { [weak self] result in
            // WhisperTranscriber already hops to main for this completion.
            guard let self = self, !self.cancelled else { return }
            self.log.info("segment \(next.index) done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            switch result {
            case .success(let text):
                self.results[next.index] = text
            case .failure(let error):
                if case WhisperTranscriberError.noSpeechDetected = error {
                    self.results[next.index] = ""   // silent segment — not an error
                } else if case WhisperTranscriberError.cancelled = error {
                    // Session is being torn down; stop here.
                    return
                } else {
                    self.lastRealError = error
                    self.results[next.index] = ""   // keep going; surface the error only if nothing usable survives
                }
            }
            // Clean up the segment file now that we're done with it.
            try? FileManager.default.removeItem(at: next.url)

            self.processedCount += 1
            self.onSegmentCompleted?(self.processedCount)
            self.isWorking = false
            self.pump()
            self.tryComplete()
        }
    }

    /// Deliver the combined result once recording has stopped (totalSegments known) and every
    /// emitted segment has been processed.
    private func tryComplete() {
        guard let total = totalSegments,
              let completion = completion,
              processedCount >= total,
              !isWorking,
              pending.isEmpty,
              !cancelled
        else { return }

        self.completion = nil
        log.info("all \(total) segment(s) done — assembling final transcript")

        let combined = (0..<total)
            .compactMap { results[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if combined.isEmpty, let error = lastRealError {
            // Nothing usable came back and at least one segment hit a real (non-silence) error.
            completion(.failure(error))
        } else {
            // Empty-but-no-error means silence: the caller maps "" to "No speech detected".
            completion(.success(combined))
        }
    }
}
