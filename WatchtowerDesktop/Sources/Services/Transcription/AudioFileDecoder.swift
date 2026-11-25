import AVFoundation
import Foundation
import os
import WatchtowerCore

enum AudioFileDecoderError: Error, LocalizedError {
    case unsupportedFormat
    case conversionFailed(String)
    /// Encoded audio with no packet table: the recorder's writer was never
    /// closed (see `AudioFileIntegrity`). Not recoverable with Apple's
    /// frameworks — the AAC decoder accepts truncated packets without an
    /// error, so the packet boundaries cannot be found by trial — so the
    /// file is kept as it is for a manual rescue.
    case notFinalized

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Audio file format is not convertible to 16 kHz mono Float32 PCM"
        case let .conversionFailed(detail):
            return "Audio conversion failed: \(detail)"
        case .notFinalized:
            return "The recording file is not finalized — its audio could not be read. The file is kept for recovery."
        }
    }
}

/// Decodes any AVFoundation-readable audio file (aac, caf, m4a, wav, …) to the raw
/// 16 kHz mono Float32 sample stream WhisperKit expects.
enum AudioFileDecoder {
    private static let log = Logger(subsystem: Constants.bundleID, category: "decoder")

    /// Decode any AVFoundation-readable file to 16 kHz mono Float32 samples.
    static func decodePCM16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        try rejectUnfinalized(length: file.length, at: url)
        let sourceFormat = file.processingFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(TranscriptionConfig.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileDecoderError.unsupportedFormat
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileDecoderError.unsupportedFormat
        }

        let inputChunkFrames: AVAudioFrameCount = 32_768
        var samples: [Float] = []
        if file.length > 0 {
            let estimated = Double(file.length) * targetFormat.sampleRate / sourceFormat.sampleRate
            samples.reserveCapacity(Int(estimated) + Int(targetFormat.sampleRate))
        }

        var reachedEnd = false
        var readError: Error?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            // EOF must be detected BEFORE reading: on compressed files (AAC in
            // aac/caf/m4a) read(into:) past the last packet throws a bridged
            // nilError instead of returning an empty buffer like PCM does.
            if reachedEnd || readError != nil || file.framePosition >= file.length {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputChunkFrames) else {
                readError = AudioFileDecoderError.conversionFailed("could not allocate read buffer")
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer)
            } catch {
                readError = error
                outStatus.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength == 0 {
                reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        let outputChunkFrames = AVAudioFrameCount(targetFormat.sampleRate) // 1 s per pull
        conversion: while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkFrames) else {
                throw AudioFileDecoderError.conversionFailed("could not allocate output buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if let readError {
                throw readError
            }
            switch status {
            case .haveData:
                try append(outBuffer, to: &samples)
            case .endOfStream:
                try append(outBuffer, to: &samples)
                break conversion
            case .inputRanDry:
                // Input block never reports .noDataNow, so a dry run means done.
                try append(outBuffer, to: &samples)
                break conversion
            case .error:
                throw conversionError ?? AudioFileDecoderError.conversionFailed("unknown converter error")
            @unknown default:
                throw AudioFileDecoderError.conversionFailed("unexpected converter status \(status.rawValue)")
            }
        }

        return samples
    }

    /// A file listing no frames is either truly empty or one whose writer
    /// never finalized it; only the header tells them apart, and the second
    /// must not pass for a recording of silence. A header that cannot be read
    /// fails the decode too, rather than passing for silence. Internal for
    /// tests.
    static func rejectUnfinalized(length: AVAudioFramePosition, at url: URL) throws {
        guard length == 0 else { return }
        let integrity: AudioFileIntegrity
        do {
            integrity = try AudioFileIntegrity.inspect(url: url)
        } catch {
            let status = (error as? AudioFileIntegrity.Unreadable)?.status ?? 0
            log.error("decode: 0 frames and the header is unreadable (OSStatus \(status, privacy: .public))")
            throw AudioFileDecoderError.conversionFailed("could not read the file header (OSStatus \(status))")
        }
        if case .unfinalized(let bytes) = integrity {
            log.error("decode: file not finalized, 0 packets in \(bytes, privacy: .public) audio bytes")
            throw AudioFileDecoderError.notFinalized
        }
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) throws {
        guard buffer.frameLength > 0 else { return }
        guard let channelData = buffer.floatChannelData else {
            throw AudioFileDecoderError.conversionFailed("output buffer has no float channel data")
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
