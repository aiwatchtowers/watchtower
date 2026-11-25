import AVFoundation
import XCTest

/// AAC-in-CAF fixtures written with the recorder's own writer settings, plus
/// an "unfinalized" variant built from one: the shape a writer that was never
/// closed leaves behind (no `pakt` packet table, `data` chunk size -1 — the
/// CAF spec's "runs to the end of the file").
enum AACFixture {
    static let sampleRate = 16_000.0

    /// Writes `durationSec` of a 440 Hz sine as 16 kHz mono AAC and closes
    /// (finalizes) the file: explicitly on macOS 15+, by deallocation before.
    static func write(durationSec: Double, fileExtension: String = "caf") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-fixture-\(UUID().uuidString).\(fileExtension)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        let frames = Int(sampleRate * durationSec)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
        let data = buffer.floatChannelData else {
            throw FixtureError.allocation
        }
        for i in 0..<frames {
            data[0][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            try file.write(from: buffer)
            if #available(macOS 15, *) { file.close() }
        }
        return url
    }

    /// An AAC CAF opened for writing and closed with nothing written: a
    /// finalized file that holds no audio at all.
    static func writeEmpty() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-empty-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ],
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            if #available(macOS 15, *) { file.close() }
        }
        return url
    }

    /// A copy of the CAF at `url` with its `pakt` chunk dropped and its
    /// `data` chunk moved last with size -1 — the bytes of every AAC packet
    /// are still there, only the table saying where each one ends is gone.
    static func unfinalizedCopy(of url: URL) throws -> URL {
        let source = try Data(contentsOf: url)
        guard source.count >= 8, source.prefix(4) == Data("caff".utf8) else { throw FixtureError.notCAF }
        var others = Data()
        var audio: Data?
        var offset = 8 // "caff" + version + flags
        while offset + 12 <= source.count {
            let type = String(bytes: source[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = source[offset + 4..<offset + 12].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            let bodyStart = offset + 12
            let bodyEnd = size < 0 ? source.count : bodyStart + Int(size)
            guard bodyEnd <= source.count else { throw FixtureError.notCAF }
            let body = source[bodyStart..<bodyEnd]
            switch type {
            case "pakt": break
            case "data": audio = Data(body)
            default: others += chunk(type, size: Int64(body.count), body: body)
            }
            offset = bodyEnd
        }
        guard let audio else { throw FixtureError.notCAF }
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("unfinalized-\(UUID().uuidString).caf")
        try (source.prefix(8) + others + chunk("data", size: -1, body: audio)).write(to: copy)
        return copy
    }

    private static func chunk(_ type: String, size: Int64, body: Data) -> Data {
        var bigEndianSize = size.bigEndian
        return Data(type.utf8) + Data(bytes: &bigEndianSize, count: 8) + body
    }

    enum FixtureError: Error {
        case allocation
        case notCAF
    }
}
