//
//  AudioExtractor.swift
//  mywisper
//
//  Created by Сергей Борисов on 06.05.2026.
//

import Foundation
import AVFoundation

/// Reads audio from any AVAsset-supported file (WAV, MP3, M4A, AAC, FLAC, AIFF,
/// MP4, MOV, M4V) and writes 16 kHz mono 16-bit PCM WAV to a temp file.
final class AudioExtractor {

    enum ExtractError: Error, LocalizedError {
        case noAudioTrack
        case readerSetupFailed(String)
        case writerSetupFailed(String)
        case readFailed(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "The file has no audio track."
            case .readerSetupFailed(let msg):
                return "Cannot read audio: \(msg)"
            case .writerSetupFailed(let msg):
                return "Cannot prepare audio for transcription: \(msg)"
            case .readFailed(let msg):
                return "Failed while reading audio: \(msg)"
            case .unreadable:
                return "This file format isn't supported. Try converting to MP3 or WAV."
            }
        }
    }

    /// Extracts and resamples the first audio track to 16 kHz mono 16-bit WAV.
    /// Returns the URL of a freshly created temp file. Caller is responsible for deleting it.
    func extractToWAV(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ExtractError.unreadable
        }
        guard let track = audioTracks.first else {
            throw ExtractError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mywisper_xfer_\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: outputURL)

        // Reader: produce 16 kHz mono 16-bit signed little-endian PCM
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExtractError.readerSetupFailed(error.localizedDescription)
        }

        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerOutputSettings)
        guard reader.canAdd(trackOutput) else {
            throw ExtractError.readerSetupFailed("Reader rejected output settings")
        }
        reader.add(trackOutput)

        // Writer: WAVE container with the same PCM format
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        } catch {
            throw ExtractError.writerSetupFailed(error.localizedDescription)
        }

        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let channelLayoutData = Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)

        let writerInputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: channelLayoutData
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw ExtractError.writerSetupFailed("Writer rejected input settings")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ExtractError.readerSetupFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw ExtractError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let processingQueue = DispatchQueue(label: "com.barssoft.mywisper.audioExtractor")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: processingQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = trackOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            writerInput.markAsFinished()
                            reader.cancelReading()
                            cont.resume(throwing: ExtractError.readFailed(
                                writer.error?.localizedDescription ?? "writer rejected sample"))
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        switch reader.status {
                        case .completed:
                            writer.finishWriting {
                                if writer.status == .completed {
                                    cont.resume()
                                } else {
                                    cont.resume(throwing: ExtractError.readFailed(
                                        writer.error?.localizedDescription ?? "finishWriting failed"))
                                }
                            }
                        case .failed, .cancelled:
                            cont.resume(throwing: ExtractError.readFailed(
                                reader.error?.localizedDescription ?? "reader stopped"))
                        default:
                            cont.resume(throwing: ExtractError.readFailed("unexpected reader state"))
                        }
                        return
                    }
                }
            }
        }

        return outputURL
    }
}
