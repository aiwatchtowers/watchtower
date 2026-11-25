import AudioToolbox
import Foundation

/// What an audio file's container says about the audio in it, read from the
/// header without decoding anything.
///
/// AAC packets vary in size, so a CAF of AAC (the recorder's format) needs its
/// packet table (`pakt` chunk) to say where each packet ends — and the writer
/// adds that table, with the real `data` chunk size, only when the file is
/// closed. A file whose writer was never closed holds every encoded byte but
/// lists 0 packets; neither AudioToolbox nor ffmpeg can find the packet
/// boundaries without the table, so it decodes to nothing.
enum AudioFileIntegrity: Equatable {
    /// The container lists `packets` (> 0) audio packets.
    case finalized(packets: Int64)
    /// `audioBytes` (> 0) of encoded audio, but no packet listed: the writer
    /// never finalized the file.
    case unfinalized(audioBytes: Int64)
    /// No audio at all.
    case empty

    /// The file could not be opened or its header read (`status` is the
    /// AudioToolbox OSStatus).
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
