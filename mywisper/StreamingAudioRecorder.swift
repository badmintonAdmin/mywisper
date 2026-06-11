//
//  StreamingAudioRecorder.swift
//  mywisper
//
//  Captures microphone audio with AVAudioEngine, resamples it to Whisper's required 16 kHz mono
//  format, and emits the audio as fixed-length WAV *segments* while recording is still going. This
//  is what powers live transcription: each finished segment can be handed to Whisper immediately,
//  so when the user stops a long dictation only the final tail remains to transcribe.
//
//  The classic single-file path (AudioRecorder) is untouched and remains the default for non-live
//  use; this type is only engaged when live transcription is enabled for the Whisper engine.
//

import AVFoundation
import CoreAudio

/// Writes signed 16-bit little-endian PCM mono WAV at a fixed sample rate, patching the RIFF/data
/// chunk sizes on close. Deliberately tiny and self-contained so segment files are always valid
/// even though we write them incrementally on a background queue.
final class SegmentWAVWriter {
    private let handle: FileHandle
    let url: URL
    private let sampleRate: Int
    private var dataBytes: Int = 0

    init?(url: URL, sampleRate: Int) {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        // 44-byte header with placeholder sizes (patched in close()).
        handle.write(Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    /// Append Float32 samples (range roughly -1...1), converting to clamped Int16.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let v = Int16(clamped * 32767.0)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        handle.write(pcm)
        dataBytes += pcm.count
    }

    /// Finalize the file: patch the two size fields and close the handle.
    func close() {
        try? handle.seek(toOffset: 4)
        handle.write(uint32LE(UInt32(36 + dataBytes)))
        try? handle.seek(toOffset: 40)
        handle.write(uint32LE(UInt32(dataBytes)))
        try? handle.close()
    }

    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * 2 // mono, 16-bit
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(uint32LE(UInt32(36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(uint32LE(16))            // fmt chunk size
        d.append(uint16LE(1))             // PCM
        d.append(uint16LE(1))             // channels = mono
        d.append(uint32LE(UInt32(sampleRate)))
        d.append(uint32LE(UInt32(byteRate)))
        d.append(uint16LE(2))             // block align
        d.append(uint16LE(16))            // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.append(uint32LE(UInt32(dataBytes)))
        return d
    }
}

private func uint32LE(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func uint16LE(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

final class StreamingAudioRecorder {
    /// Whisper's required sample rate.
    private static let targetSampleRate = 16000

    /// Minimum recording length; anything shorter is discarded as an accidental tap (mirrors
    /// AudioRecorder so the two paths behave identically on short presses).
    static let minimumDuration: TimeInterval = 0.3

    /// Current audio level (0...1), reported ~10×/sec for the overlay meter.
    var onAudioLevel: ((Float) -> Void)?

    /// Called on the main queue when a segment WAV is finalized and ready to transcribe.
    /// Segments arrive strictly in order, indexed from 0.
    var onSegmentReady: ((_ url: URL, _ index: Int) -> Void)?

    /// Called on the main queue exactly once after `stop()`, after the final tail segment has been
    /// emitted. Reports how many segments were produced in total and the full recording duration,
    /// plus whether the whole thing was too short to keep.
    var onFinished: ((_ totalSegments: Int, _ duration: TimeInterval, _ tooShort: Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat!

    /// All segment writing happens on this serial queue so the realtime audio thread only converts
    /// + copies samples, never touches the filesystem or the segment-rotation bookkeeping.
    private let segmentQueue = DispatchQueue(label: "com.barssoft.mywisper.live-segments")

    private var currentWriter: SegmentWAVWriter?
    private var currentSegmentSamples = 0
    /// Preferred (minimum) segment length: once past this we cut at the next silence.
    private var minSegmentSamples = 0
    /// Hard ceiling: if no pause is found, cut anyway so segments stay bounded.
    private var maxSegmentSamples = 0
    /// Running count of consecutive near-silent samples, used to find a clean cut point.
    private var silentRunSamples = 0
    private var nextSegmentIndex = 0
    private var totalSamples = 0
    private let sessionID = UUID().uuidString

    /// Below this level (dBFS) a block counts as silence for the purpose of finding a cut point.
    private static let silenceDb: Float = -40
    /// How much continuous silence (seconds) marks a safe place to end a segment.
    private static let silenceRunSeconds = 0.35
    /// Headroom (seconds) past the minimum before we *force* a cut. This only acts as a safety
    /// valve to bound memory/disk if the speaker never pauses — segments are meant to be cut at
    /// silence (see `appendSamples`). It is deliberately large because a forced cut lands
    /// mid-word and degrades Whisper at that seam, whereas a silence cut is lossless.
    private static let maxHeadroomSeconds = 240.0

    private var previousDefaultInputDeviceID: AudioDeviceID?

    func start(segmentSeconds: Double) throws {
        minSegmentSamples = Int(segmentSeconds * Double(Self.targetSampleRate))
        maxSegmentSamples = Int((segmentSeconds + Self.maxHeadroomSeconds) * Double(Self.targetSampleRate))
        nextSegmentIndex = 0
        totalSamples = 0
        currentSegmentSamples = 0
        silentRunSamples = 0
        currentWriter = nil

        applySelectedInputDevice()

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.invalidFormat
        }
        outputFormat = outFormat

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            // No usable input format usually means the mic isn't available / permission denied.
            restoreDefaultInputDevice()
            throw AudioRecorderError.recordingFailed
        }
        converter = AVAudioConverter(from: inputFormat, to: outFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            restoreDefaultInputDevice()
            throw error
        }
    }

    private func handleTap(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter = converter, buffer.frameLength > 0 else { return }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        var convErr: NSError?
        converter.convert(to: outBuffer, error: &convErr, withInputFrom: inputBlock)
        guard outBuffer.frameLength > 0, let ch = outBuffer.floatChannelData else { return }

        let n = Int(outBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))

        // Audio level (RMS → dB → 0...1), matching AudioRecorder's normalization.
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(n))
        let dB = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (dB + 50) / 50))
        if let onAudioLevel = onAudioLevel {
            DispatchQueue.main.async { onAudioLevel(level) }
        }
        let isSilent = dB < Self.silenceDb

        // Hand the samples off to the serial writer queue.
        segmentQueue.async { [weak self] in
            self?.appendSamples(samples, isSilent: isSilent)
        }
    }

    /// Runs on `segmentQueue`. Appends samples to the current segment and rotates to a new segment
    /// file at a silence boundary once past the minimum length — so segments never split a word
    /// mid-utterance (which badly degrades Whisper). Falls back to a hard cut at the max length if
    /// the speaker never pauses.
    private func appendSamples(_ samples: [Float], isSilent: Bool) {
        if currentWriter == nil {
            currentWriter = makeWriter(index: nextSegmentIndex)
        }
        currentWriter?.append(samples)
        currentSegmentSamples += samples.count
        totalSamples += samples.count

        silentRunSamples = isSilent ? silentRunSamples + samples.count : 0

        guard minSegmentSamples > 0 else { return }
        let silenceRunNeeded = Int(Self.silenceRunSeconds * Double(Self.targetSampleRate))
        let reachedMin = currentSegmentSamples >= minSegmentSamples
        let foundPause = silentRunSamples >= silenceRunNeeded
        let reachedMax = currentSegmentSamples >= maxSegmentSamples

        if (reachedMin && foundPause) || reachedMax {
            finalizeCurrentSegment()
            silentRunSamples = 0
        }
    }

    /// Runs on `segmentQueue`. Closes the current writer and notifies the listener.
    private func finalizeCurrentSegment() {
        guard let writer = currentWriter else { return }
        writer.close()
        let url = writer.url
        let index = nextSegmentIndex
        currentWriter = nil
        currentSegmentSamples = 0
        nextSegmentIndex += 1
        DispatchQueue.main.async { [weak self] in
            self?.onSegmentReady?(url, index)
        }
    }

    private func makeWriter(index: Int) -> SegmentWAVWriter? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mywisper_live_\(sessionID)_\(index).wav")
        try? FileManager.default.removeItem(at: url)
        return SegmentWAVWriter(url: url, sampleRate: Self.targetSampleRate)
    }

    /// Stop recording. Flushes any remaining audio as a final segment, then fires `onFinished`.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restoreDefaultInputDevice()

        segmentQueue.async { [weak self] in
            guard let self = self else { return }
            // Emit the tail (partial) segment if it holds any audio.
            if self.currentWriter != nil, self.currentSegmentSamples > 0 {
                self.finalizeCurrentSegment()
            } else {
                self.currentWriter?.close()
                self.currentWriter = nil
            }
            let total = self.nextSegmentIndex
            let duration = Double(self.totalSamples) / Double(Self.targetSampleRate)
            let tooShort = duration < Self.minimumDuration
            DispatchQueue.main.async { [weak self] in
                self?.onFinished?(total, duration, tooShort)
            }
        }
    }

    /// Abort recording and delete every segment file produced this session.
    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restoreDefaultInputDevice()
        onAudioLevel = nil
        onSegmentReady = nil
        onFinished = nil
        let id = sessionID
        let count = nextSegmentIndex + 1
        segmentQueue.async {
            self.currentWriter?.close()
            self.currentWriter = nil
            let tmp = FileManager.default.temporaryDirectory
            for i in 0..<max(count, 1) {
                let url = tmp.appendingPathComponent("mywisper_live_\(id)_\(i).wav")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Input device selection (mirrors AudioRecorder)

    private func applySelectedInputDevice() {
        previousDefaultInputDeviceID = nil
        let savedID = SettingsManager.shared.selectedInputDeviceID
        guard !savedID.isEmpty else { return }
        guard let target = AudioInputDevices.available().first(where: { $0.uniqueID == savedID }) else { return }
        if let current = AudioInputDevices.currentDefaultInputDeviceID(), current != target.coreAudioID {
            previousDefaultInputDeviceID = current
            AudioInputDevices.setDefaultInputDevice(target.coreAudioID)
        }
    }

    private func restoreDefaultInputDevice() {
        if let previous = previousDefaultInputDeviceID {
            AudioInputDevices.setDefaultInputDevice(previous)
            previousDefaultInputDeviceID = nil
        }
    }
}
