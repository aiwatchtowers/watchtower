import Foundation
import os

/// A debug meter of the phone's relay traffic and wakes, read by a measuring run: bytes per `changes` page and per
/// download, and the `fetchForPush` calls. Numbers only, never a record name, id or hub name. Under `#if DEBUG`
/// only; a Release build has the empty shape below, whose calls are no-ops, so the transport code is the same in
/// both configurations. Owned by the transport actor: it moves only with a page or download that went out, so a
/// stopped or parked feed adds nothing.
#if DEBUG
struct RelayTrafficMeter: Equatable {
    var pages = 0
    var bytes = 0
    var downloads = 0
    var downloadBytes = 0
    var wakes = 0
    private var logged = RelayTrafficMeterTotals()

    mutating func recordPage(bytes: Int) {
        pages += 1
        self.bytes += bytes
    }

    mutating func recordDownload(bytes: Int) {
        downloads += 1
        downloadBytes += bytes
    }

    mutating func recordWake() { wakes += 1 }

    /// The one line of a pass: `relay traffic: pages N, bytes B, downloads D, download bytes E, wakes W`.
    var line: String {
        "relay traffic: pages \(pages), bytes \(bytes), downloads \(downloads), download bytes \(downloadBytes), wakes \(wakes)"
    }

    /// Logs `line` at notice level when anything moved since the last log (a pass that sent nothing logs nothing).
    mutating func logPass(to logger: Logger) {
        let now = RelayTrafficMeterTotals(pages: pages, bytes: bytes, downloads: downloads, downloadBytes: downloadBytes, wakes: wakes)
        guard now != logged else { return }
        logged = now
        let text = line
        logger.notice("\(text, privacy: .public)")
    }
}

private struct RelayTrafficMeterTotals: Equatable {
    var pages = 0
    var bytes = 0
    var downloads = 0
    var downloadBytes = 0
    var wakes = 0
}
#else
struct RelayTrafficMeter {
    @inline(__always) mutating func recordPage(bytes: Int) {}
    @inline(__always) mutating func recordDownload(bytes: Int) {}
    @inline(__always) mutating func recordWake() {}
    @inline(__always) mutating func logPass(to logger: Logger) {}
}
#endif
