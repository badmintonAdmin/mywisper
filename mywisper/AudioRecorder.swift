//
//  AudioRecorder.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import AVFoundation

class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var tempFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mywisper_recording.wav")
    }

    /// Current audio level (0.0 to 1.0), updated ~30 times per second
    var onAudioLevel: ((Float) -> Void)?

    /// Minimum recording length; anything shorter is discarded as an accidental tap.
    static let minimumDuration: TimeInterval = 0.3

    /// True when the most recent `stopRecordingAndGetURL()` returned nil specifically because
    /// the recording was shorter than `minimumDuration` (as opposed to no recorder at all).
    private(set) var lastRecordingWasTooShort = false

    func startRecording() throws {
        try? FileManager.default.removeItem(at: tempFileURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let rec = try AVAudioRecorder(url: tempFileURL, settings: settings)
        rec.isMeteringEnabled = true
        rec.prepareToRecord()

        guard rec.record() else {
            throw AudioRecorderError.recordingFailed
        }

        self.recorder = rec

        // Start metering timer for audio level visualization
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let rec = self.recorder else { return }
            rec.updateMeters()
            let dB = rec.averagePower(forChannel: 0) // -160 to 0
            // Normalize: -50 dB → 0.0, 0 dB → 1.0
            let normalized = max(0, min(1, (dB + 50) / 50))
            self.onAudioLevel?(normalized)
        }
    }

    /// Stop recording and return the audio file URL
    func stopRecordingAndGetURL() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        onAudioLevel?(0)
        lastRecordingWasTooShort = false

        guard let rec = recorder else { return nil }

        let duration = rec.currentTime
        rec.stop()
        self.recorder = nil

        guard duration > Self.minimumDuration else {
            lastRecordingWasTooShort = true
            return nil
        }

        return tempFileURL
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case invalidFormat
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid audio input format."
        case .recordingFailed:
            return "Failed to start recording."
        }
    }
}
