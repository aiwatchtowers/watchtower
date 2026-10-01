import Foundation

package extension FileHandle {
    /// The handle's lines, framed on byte 0x0A only (`NDJSONLineSplitter`),
    /// ending at EOF with any unterminated tail. Read through
    /// `readabilityHandler` — never `bytes`/`bytes.lines`: Foundation runs
    /// every `AsyncBytes` read in the process on ONE actor as a blocking
    /// `read()`, so one reader parked on a silent pipe (an idle warm chat
    /// session) stalls every other reader until that pipe speaks or closes.
    ///
    /// Read the stream once; ending the iteration early stops the reads.
    var ndjsonLines: AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let splitter = LockedSplitter()
        readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if let tail = splitter.finish() { continuation.yield(tail) }
                continuation.finish()
                return
            }
            for line in splitter.append(data) { continuation.yield(line) }
        }
        continuation.onTermination = { [weak self] _ in self?.readabilityHandler = nil }
        return stream
    }
}

/// `readabilityHandler` runs on a Foundation-owned queue; the lock keeps the
/// splitter's partial line consistent should two callbacks ever overlap.
private final class LockedSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = NDJSONLineSplitter()

    func append(_ data: Data) -> [String] {
        lock.withLock { splitter.append(data) }
    }

    func finish() -> String? {
        lock.withLock { splitter.finish() }
    }
}
