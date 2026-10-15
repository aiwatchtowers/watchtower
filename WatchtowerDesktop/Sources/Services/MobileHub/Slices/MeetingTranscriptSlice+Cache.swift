import Foundation

extension MeetingTranscriptSlice {
    /// `@unchecked Sendable`: every field is guarded by `lock`.
    final class BuildCache: @unchecked Sendable {
        struct Entry {
            let fingerprint: Data
            /// The row's light key when it had settled; nil: read it in full.
            var light: Data?
            let payload: Data
            let digest: Data
        }

        private let lock = NSLock()
        private var entries: [Int64: Entry] = [:]
        private var buildCount = 0
        private var fullReadCount = 0
        private var recapReadCount = 0

        var builds: Int { lock.withLock { buildCount } }
        var fullReads: Int { lock.withLock { fullReadCount } }
        var recapReads: Int { lock.withLock { recapReadCount } }

        func entry(_ id: Int64) -> Entry? {
            lock.withLock { entries[id] }
        }

        func setLight(_ light: Data?, for id: Int64) {
            lock.withLock { entries[id]?.light = light }
        }

        func countFullReads(_ count: Int) {
            lock.withLock { fullReadCount += count }
        }

        func countRecapReads(_ count: Int) {
            lock.withLock { recapReadCount += count }
        }

        func store(_ id: Int64, _ entry: Entry) {
            lock.withLock {
                entries[id] = entry
                buildCount += 1
            }
        }

        /// Forgets transcripts that left the window.
        func prune(keeping ids: Set<Int64>) {
            lock.withLock { entries = entries.filter { ids.contains($0.key) } }
        }
    }
}
