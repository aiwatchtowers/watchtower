import Foundation
import GRDB
import os

// Desktop half of the SQLite write-lock metrics (#527). The Go processes
// write the same <workspace>/dblock.jsonl through internal/db/lockmetrics;
// that package doc is the write and rotation protocol this file follows,
// and its Event JSON keys are the contract `watchtower db lockstats` reads.

/// `WATCHTOWER_DBLOCK_THRESHOLD_MS`, read the way the Go sink reads it:
/// unset or empty → 200 ms, an integer ≥ 0 → that many ms (0 records every
/// transaction), `off` (any case) → disabled, anything else → 200 ms.
package struct DBLockSettings: Equatable, Sendable {
    package static let defaultThresholdMS: Int64 = 200
    static let environmentKey = "WATCHTOWER_DBLOCK_THRESHOLD_MS"

    package var off: Bool
    package var thresholdMS: Int64

    package init(off: Bool = false, thresholdMS: Int64 = Self.defaultThresholdMS) {
        self.off = off
        self.thresholdMS = thresholdMS
    }

    package static func parse(_ raw: String?) -> Self {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return Self() }
        if value.lowercased() == "off" { return Self(off: true) }
        guard let ms = Int64(value), ms >= 0 else {
            DBLockSink.log.warning(
                "invalid \(environmentKey, privacy: .public)=\(value, privacy: .public); using the default \(defaultThresholdMS) ms")
            return Self()
        }
        return Self(thresholdMS: ms)
    }

    package static func fromEnvironment() -> Self {
        parse(ProcessInfo.processInfo.environment[environmentKey])
    }
}

/// One line of dblock.jsonl, minus `pid`/`proc`, which the sink fills.
package struct DBLockEvent: Equatable, Sendable {
    package static let kindTx = "tx"
    package static let kindBusy = "busy"

    package var ts: Date
    package var kind: String
    package var waitMS: Int64 = 0
    package var holdMS: Int64 = 0
    package var site: String = ""
    package var err: String = ""
    package var busyTimeoutMS: Int64 = 0

    package init(
        ts: Date = Date(),
        kind: String,
        waitMS: Int64 = 0,
        holdMS: Int64 = 0,
        site: String = "",
        err: String = "",
        busyTimeoutMS: Int64 = 0
    ) {
        self.ts = ts
        self.kind = kind
        self.waitMS = waitMS
        self.holdMS = holdMS
        self.site = site
        self.err = err
        self.busyTimeoutMS = busyTimeoutMS
    }
}

/// Appends events to dblock.jsonl next to the DB file, off the caller's
/// thread on one serial queue. Best effort: a failure is logged once and
/// later ones are dropped, so a metrics failure never reaches a DB write.
package final class DBLockSink: @unchecked Sendable {
    package static let fileName = "dblock.jsonl"
    /// The sidecar every writer flocks to rotate the sink (never deleted).
    package static let lockFileName = fileName + ".lock"
    package static let maxFileBytes: Int64 = 10 << 20
    package static let proc = "desktop"

    static let log = Logger(subsystem: "com.watchtower.desktop", category: "dblock")

    package let path: String
    package let settings: DBLockSettings
    private let lockPath: String
    private let maxFileBytes: Int64
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let queue = DispatchQueue(label: "watchtower.dblock-sink", qos: .utility)

    // Confined to `queue`.
    private var fd: Int32 = -1
    private var heldDev: dev_t = 0
    private var heldIno: ino_t = 0
    private var warned = false
    private let tsFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    /// nil when the env turns the metrics off or the DB is in memory.
    package init?(
        dbPath: String,
        settings: DBLockSettings = .fromEnvironment(),
        maxFileBytes: Int64 = DBLockSink.maxFileBytes
    ) {
        guard !settings.off, !dbPath.isEmpty, dbPath != ":memory:" else { return nil }
        let dir = (dbPath as NSString).deletingLastPathComponent
        self.path = (dir as NSString).appendingPathComponent(Self.fileName)
        self.lockPath = (dir as NSString).appendingPathComponent(Self.lockFileName)
        self.settings = settings
        self.maxFileBytes = maxFileBytes
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Whether a transaction with this wait and hold is worth a `tx` line.
    package func isSlow(waitMS: Int64, holdMS: Int64) -> Bool {
        waitMS >= settings.thresholdMS || holdMS >= settings.thresholdMS
    }

    /// Queues one line. Does not apply the threshold — check `isSlow` first.
    package func record(_ event: DBLockEvent) {
        queue.async { [self] in
            appendLine(line(for: event))
        }
    }

    /// Waits until every queued line is written (tests).
    package func flush() {
        queue.sync {}
    }

    func line(for event: DBLockEvent) -> Data {
        // Key order is irrelevant; zero values are omitted like Go's omitempty.
        var obj: [String: Any] = [
            "ts": tsFormatter.string(from: event.ts),
            "pid": Int(pid),
            "proc": Self.proc,
            "kind": event.kind
        ]
        if event.waitMS != 0 { obj["wait_ms"] = event.waitMS }
        if event.holdMS != 0 { obj["hold_ms"] = event.holdMS }
        if !event.site.isEmpty { obj["site"] = event.site }
        if !event.err.isEmpty { obj["err"] = event.err }
        if event.busyTimeoutMS != 0 { obj["busy_timeout_ms"] = event.busyTimeoutMS }
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Writes one line through the held descriptor. The path is stat'ed
    /// first: a file another process rotated away (or deleted) is closed and
    /// re-opened, and a file past the cap is rotated to .1 before the write.
    private func appendLine(_ line: Data) {
        guard line.count > 1 else { return }
        var cur = stat()
        let found = stat(path, &cur) == 0
        if fd >= 0, !found || cur.st_dev != heldDev || cur.st_ino != heldIno {
            closeHeld()
        }
        if found, Int64(cur.st_size) > maxFileBytes {
            rotate(seen: cur)
            closeHeld()
        }
        if fd < 0 {
            let opened = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, mode_t(0o600))
            guard opened >= 0 else { return warn("open") }
            var held = stat()
            guard fstat(opened, &held) == 0 else {
                close(opened)
                return warn("stat")
            }
            fd = opened
            heldDev = held.st_dev
            heldIno = held.st_ino
        }
        // One write per line: O_APPEND keeps concurrent writers' lines whole.
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != line.count {
            warn("write")
            closeHeld()
        }
    }

    /// Moves the full sink to .1 under a non-blocking flock on the sidecar,
    /// only if the path still names the inode seen over the cap and is still
    /// over it — a writer that lost the race never moves the fresh file over
    /// the generation the winner just rotated. A held lock means another
    /// writer is rotating: skip, never wait.
    private func rotate(seen: stat) {
        let lockFD = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else { return warn("open rotation lock") }
        defer { close(lockFD) } // closing releases the flock
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno != EWOULDBLOCK && errno != EINTR { warn("lock for rotation") }
            return
        }
        var cur = stat()
        guard stat(path, &cur) == 0, cur.st_dev == seen.st_dev, cur.st_ino == seen.st_ino,
              Int64(cur.st_size) > maxFileBytes else { return }
        if rename(path, path + ".1") != 0 { warn("rotate") }
    }

    private func closeHeld() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    private func warn(_ op: String) {
        let code = errno
        guard !warned else { return }
        warned = true
        Self.log.warning(
            "dblock sink: \(op, privacy: .public) failed for \(self.path, privacy: .public) (errno \(code)); further sink errors are dropped")
    }
}

/// SQLite's default busy handler schedule (`sqliteDefaultBusyCallback`), so
/// the GRDB busy callback that measures the wait sleeps exactly like the
/// `PRAGMA busy_timeout` it replaces.
package enum SQLiteBusyWait {
    private static let delays = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]
    private static let totals = [0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228]

    /// Milliseconds to sleep before retry number `tries` (0-based), or nil
    /// once the timeout is spent and the handler gives up with SQLITE_BUSY.
    package static func delayMS(tries: Int, timeoutMS: Int) -> Int? {
        var delay: Int
        let prior: Int
        if tries < delays.count {
            delay = delays[tries]
            prior = totals[tries]
        } else {
            delay = delays[delays.count - 1]
            prior = totals[totals.count - 1] + delay * (tries - (delays.count - 1))
        }
        if prior + delay > timeoutMS {
            delay = timeoutMS - prior
            if delay <= 0 { return nil }
        }
        return delay
    }
}

/// Wires the lock metrics into a `DatabasePool` configuration.
package enum DBLockInstrumentation {
    /// The busy budget the Desktop has always used (`PRAGMA busy_timeout = 5000`).
    package static let busyTimeoutMS = 5000
    private static let busyStartKey = "watchtower.dblock.busyStart"

    /// The writer waits through a busy callback with SQLite's own schedule
    /// and budget, recording a `busy` event when it gives up; it also gets a
    /// profile trace that records slow transactions. Readers keep the plain
    /// `PRAGMA busy_timeout` (GRDB opens them `readonly`, and their busy
    /// mode would otherwise default to GRDB's 10 s). A nil sink keeps the
    /// waiting behaviour and records nothing.
    package static func install(
        on config: inout Configuration,
        sink: DBLockSink?,
        busyTimeoutMS: Int = Self.busyTimeoutMS
    ) {
        config.busyMode = .callback { tries in
            // Every retry of one wait runs synchronously on the thread that
            // stepped the statement, so a thread-local marks its start.
            let now = DispatchTime.now().uptimeNanoseconds
            let thread = Thread.current.threadDictionary
            if tries == 0 { thread[busyStartKey] = NSNumber(value: now) }
            guard let delay = SQLiteBusyWait.delayMS(tries: tries, timeoutMS: busyTimeoutMS) else {
                let start = (thread[busyStartKey] as? NSNumber)?.uint64Value ?? now
                sink?.record(DBLockEvent(
                    kind: DBLockEvent.kindBusy, waitMS: Int64((now - start) / 1_000_000),
                    site: WriteTransactionTracker.unknownSite, err: "SQLITE_BUSY",
                    busyTimeoutMS: Int64(busyTimeoutMS)))
                return false
            }
            usleep(useconds_t(delay * 1000))
            return true
        }
        config.prepareDatabase { db in
            if db.configuration.readonly {
                try db.execute(sql: "PRAGMA busy_timeout = \(busyTimeoutMS)")
            } else if let sink {
                let tracker = WriteTransactionTracker(sink: sink)
                db.trace(options: .profile) { tracker.observe($0) }
            }
        }
    }
}

/// Measures BEGIN → COMMIT/ROLLBACK on the writer connection from its
/// profile trace: `wait_ms` is the BEGIN IMMEDIATE's own duration (the
/// write-lock wait), `hold_ms` runs from BEGIN done to COMMIT/ROLLBACK done.
/// Confined to the writer connection's queue.
final class WriteTransactionTracker {
    static let unknownSite = "desktop:?"

    private let sink: DBLockSink
    private var beganAt: UInt64?
    private var waitMS: Int64 = 0
    private var table: String?

    init(sink: DBLockSink) {
        self.sink = sink
    }

    func observe(_ event: Database.TraceEvent) {
        guard case let .profile(statement, duration) = event else { return }
        observe(sql: statement.sql, duration: duration, now: DispatchTime.now().uptimeNanoseconds)
    }

    func observe(sql: String, duration: TimeInterval, now: UInt64) {
        switch Self.boundary(sql) {
        case .begin:
            // A BEGIN that failed busy leaves no transaction; the next BEGIN
            // starts over and no COMMIT ever closes the stale one.
            beganAt = now
            waitMS = Int64(duration * 1000)
            table = nil
        case .end:
            guard let began = beganAt else { return }
            beganAt = nil
            let holdMS = Int64((now &- began) / 1_000_000)
            guard sink.isSlow(waitMS: waitMS, holdMS: holdMS) else { return }
            sink.record(DBLockEvent(
                kind: DBLockEvent.kindTx, waitMS: waitMS, holdMS: holdMS,
                site: table.map { "desktop:\($0)" } ?? Self.unknownSite))
        case nil:
            if beganAt != nil, table == nil { table = Self.writtenTable(sql) }
        }
    }

    enum Boundary { case begin, end }

    static func boundary(_ sql: String) -> Boundary? {
        let head = sql.prefix(9).uppercased()
        if head.hasPrefix("BEGIN") { return .begin }
        if head.hasPrefix("COMMIT") || head.hasPrefix("END") { return .end }
        if head.hasPrefix("ROLLBACK") {
            // ROLLBACK TO SAVEPOINT keeps the transaction open.
            return sql.range(of: " TO ", options: .caseInsensitive) == nil ? .end : nil
        }
        return nil
    }

    /// The table an INSERT/REPLACE/UPDATE/DELETE writes, or nil for any
    /// other statement.
    static func writtenTable(_ sql: String) -> String? {
        let words = sql.split { $0.isWhitespace || $0 == "(" }.prefix(6).map { String($0) }
        guard let verb = words.first?.uppercased() else { return nil }
        var rest = words.dropFirst()
        switch verb {
        case "INSERT", "REPLACE":
            guard let into = rest.firstIndex(where: { $0.uppercased() == "INTO" }) else { return nil }
            rest = rest[(into + 1)...]
        case "UPDATE":
            if rest.first?.uppercased() == "OR" { rest = rest.dropFirst(2) }
        case "DELETE":
            guard rest.first?.uppercased() == "FROM" else { return nil }
            rest = rest.dropFirst()
        default:
            return nil
        }
        guard let name = rest.first else { return nil }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[];"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
