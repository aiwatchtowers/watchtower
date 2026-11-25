import AudioToolbox
import Foundation

/// What an audio file's container says about the audio in it, read from the
/// header without decoding anything.
///
/// AAC packets vary in size, so a CAF of AAC (the recorder's format before
/// ADTS) needs its packet table (`pakt` chunk) to say where each packet ends —
/// and the writer adds that table, with the real `data` chunk size, only when
/// the file is closed. A CAF whose writer was never closed holds every encoded
/// byte but lists 0 packets; neither AudioToolbox nor ffmpeg can find the
/// packet boundaries without the table, so it decodes to nothing.
///
/// ADTS (`.aac`, today's recorder format) has no such state: each packet
/// carries a header with its own length, so AudioToolbox counts the packets by
/// scanning the file, and one whose writer was never closed lists every packet
/// that reached the disk (`.finalized`). An ADTS file with no complete packet
/// cannot be opened at all (`Unreadable`), which is how a zero-byte one fails.
enum AudioFileIntegrity: Equatable {
    /// The container lists `packets` (> 0) audio packets: a closed CAF, or
    /// any ADTS file with a readable packet, closed or not.
    case finalized(packets: Int64)
    /// `audioBytes` (> 0) of encoded audio, but no packet listed: the writer
    /// never finalized the file (a CAF without its packet table).
    case unfinalized(audioBytes: Int64)
    /// No audio at all.
    case empty

    /// The file could not be opened or its header read (`status` is the
    /// AudioToolbox OSStatus) — for ADTS, also a file with no complete packet.
    struct Unreadable: Error, Equatable {
        let status: OSStatus
    }

    static func inspect(url: URL) throws -> Self {
        var opened: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened)
        guard openStatus == noErr, let file = opened else { throw Unreadable(status: openStatus) }
        defer { AudioFileClose(file) }
        let packets = try uint64Property(kAudioFilePropertyAudioDataPacketCount, of: file)
        if packets > 0 { return .finalized(packets: Int64(clamping: packets)) }
        let bytes = try uint64Property(kAudioFilePropertyAudioDataByteCount, of: file)
        return bytes > 0 ? .unfinalized(audioBytes: Int64(clamping: bytes)) : .empty
    }

    private static func uint64Property(_ property: AudioFilePropertyID, of file: AudioFileID) throws -> UInt64 {
        var value: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        let status = AudioFileGetProperty(file, property, &size, &value)
        guard status == noErr else { throw Unreadable(status: status) }
        return value
    }
}
