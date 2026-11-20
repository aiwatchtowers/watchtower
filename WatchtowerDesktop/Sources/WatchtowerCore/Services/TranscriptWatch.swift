import Combine
import Foundation
import os
import WatchtowerChatText

/// What a watched file did: written or grown in place, or renamed/deleted
/// (the source then watches a file no longer at its path).
package enum FileEvent: Sendable, Equatable {
    case changed
    case replaced
}

/// Opens a change watch on one file or directory. A directory reports only
/// entries added or removed, never writes into its files.
@MainActor
package protocol FileEventSource {
    func open(_ path: String, onEvent: @escaping @Sendable (FileEvent) -> Void) throws -> any Cancellable
}

/// The live source: one kqueue vnode `DispatchSource` per path, delivering on
/// the main queue.
package struct DispatchFileEventSource: FileEventSource {
    package nonisolated init() {}

    package func open(_ path: String, onEvent: @escaping @Sendable (FileEvent) -> Void) throws -> any Cancellable {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak source] in
            guard let mask = source?.data else { return }
            onEvent(mask.contains(.rename) || mask.contains(.delete) ? .replaced : .changed)
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return AnyCancellable { source.cancel() }
    }
}

/// The watch's time: `now` and one-shot timers on the main actor. Tests
/// inject a manual clock, so no test waits on wall time.
@MainActor
package protocol TranscriptWatchClock {
    var now: ContinuousClock.Instant { get }
    func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor () -> Void) -> any Cancellable
}

/// The live clock. `ContinuousClock` keeps counting while the Mac sleeps, so
/// its timers run on the wall clock (`DispatchWallTime`), which does too.
package struct MainQueueWatchClock: TranscriptWatchClock {
    package nonisolated init() {}

    package var now: ContinuousClock.Instant { .now }

    package func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        let delay = max(.zero, ContinuousClock.now.duration(to: deadline)).components
        let seconds = Double(delay.seconds) + Double(delay.attoseconds) / 1e18
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: item)
        return AnyCancellable { item.cancel() }
    }
}

/// The watch's bounds; `standard` is the spec's (§8).
package struct TranscriptWatchTiming: Sendable, Equatable {
    package var debounce: Duration
    package var minGap: Duration
    package var fallback: Duration

    package static let standard = Self(debounce: .milliseconds(250), minGap: .seconds(1), fallback: .seconds(3))

    /// One interval for every bound (a test's fast cadence).
    package static func uniform(_ interval: Duration) -> Self {
        Self(debounce: interval, minGap: interval, fallback: interval)
    }
}

/// What one read says to watch.
package struct TranscriptWatchTargets: Equatable, Sendable {
    /// `paths` of the read (`workbench session-feed --json`).
    package var paths: [String]
    /// The conversation files being followed, in priority order: the
    /// current conversation (or the subagent's own transcript, then its
    /// parent's).
    package var current: [String]
    /// Agent ids the newest read calls running.
    package var running: Set<String>
    /// The running agents of the live snapshot: while one has no transcript
    /// listed yet (a Codex rollout made later in another date directory),
    /// nothing would report its change, so the fallback tick runs.
    package var mustCover: Set<String>

    package init(paths: [String] = [], current: [String] = [], running: Set<String> = [], mustCover: Set<String> = []) {
        self.paths = paths; self.current = current; self.running = running; self.mustCover = mustCover
    }
}

/// Asks for a Workchat read when a followed file changes, instead of a 3 s
/// poll (spec `2026-11-20-phone-workchat-live-design.md` §8). At most
/// `maxSources` sources, opened in this order: the current conversation's
/// files, their directories (a new conversation or subagent file appears
/// there), the current conversation's `subagents/` directory, then the
/// running agents' transcripts and sidecars. Older conversations and
/// finished agents are not watched.
///
/// One timer serves both causes of a read, inside one minimum gap: a change
/// is read `debounce` after its last event, and at most once per `minGap`
/// while events keep coming (a burst never starves it); while the watch has
/// no open source, a path failed to open or was cut by the cap, or the last
/// read failed, it also reads `fallback` after the last read. A source
/// opened after a read asks for one more read, so a change between that
/// read and the open is never missed; that read opens nothing new.
@MainActor
package final class TranscriptWatch {
    package static let maxSources = 32

    private let fileEvents: FileEventSource
    private let clock: TranscriptWatchClock
    private let timing: TranscriptWatchTiming
    private let onRefresh: @MainActor () -> Void
    private var targets = TranscriptWatchTargets()
    private var sources: [String: any Cancellable] = [:]
    package private(set) var isRunning = false
    private var openFailed = false
    private var readFailed = false
    /// The first unanswered event and the last one; nil when clean.
    private var dirtySince: ContinuousClock.Instant?
    private var lastEvent: ContinuousClock.Instant?
    private var lastRead: ContinuousClock.Instant?
    private var fallbackSince: ContinuousClock.Instant?
    private var timer: (any Cancellable)?
    private var loggedOpenFailures: Set<String> = []
    private var loggedNoPaths = false
    private var loggedUncovered = false

    package init(
        fileEvents: FileEventSource,
        clock: TranscriptWatchClock,
        timing: TranscriptWatchTiming = .standard,
        onRefresh: @escaping @MainActor () -> Void
    ) {
        self.fileEvents = fileEvents
        self.clock = clock
        self.timing = timing
        self.onRefresh = onRefresh
    }

    /// The paths with an open source.
    package var watchedPaths: Set<String> { Set(sources.keys) }
    /// Reads also come from the fallback timer.
    package var isFallback: Bool { isRunning && (sources.isEmpty || openFailed || readFailed) }
    /// Every change reaches the watch: it runs, every followed file is
    /// open and the last read succeeded. A quiet transcript then means
    /// nothing happened, not that the pane is out of date (spec C4).
    package var isHealthy: Bool { isRunning && !isFallback }

    /// A read came back: follow its targets (applied at once while running,
    /// kept for `start()` otherwise). `readFailed` keeps the fallback tick
    /// (a follow whose other read failed).
    package func update(_ targets: TranscriptWatchTargets, readFailed: Bool = false) {
        self.targets = targets
        self.readFailed = readFailed
        guard isRunning else { return }
        apply()
    }

    /// A read failed: the fallback timer reads until one succeeds.
    package func markReadFailed() {
        readFailed = true
        reschedule()
    }

    /// A read is starting: it covers every event so far.
    package func readStarted() {
        lastRead = clock.now
        dirtySince = nil; lastEvent = nil
        reschedule()
    }

    /// Opens the sources of the last targets.
    package func start() {
        guard !isRunning else { return }
        isRunning = true
        apply()
    }

    /// Closes every source and timer; `start()` opens them again.
    package func stop() {
        isRunning = false
        for source in sources.values { source.cancel() }
        sources = [:]
        timer?.cancel(); timer = nil
        dirtySince = nil; lastEvent = nil; fallbackSince = nil
    }

    /// The id a transcript or sidecar file name carries: `agent-<id>.jsonl`
    /// and `agent-<id>.meta.json` (a Claude subagent), `rollout-<time>-<uuid>.jsonl`
    /// (a Codex thread), `<id>.jsonl` (a Claude conversation); nil otherwise.
    package static func fileID(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("agent-") {
            for ext in [".meta.json", ".jsonl"] where name.hasSuffix(ext) {
                let id = String(name.dropFirst("agent-".count).dropLast(ext.count))
                return id.isEmpty ? nil : id
            }
            return nil
        }
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        if stem.hasPrefix("rollout-") {
            let id = String(stem.suffix(36))
            return UUID(uuidString: id) != nil ? id : nil
        }
        return stem.isEmpty ? nil : stem
    }

    /// The paths to watch in priority order, how many the cap cut, and
    /// whether a `mustCover` agent has no transcript listed.
    package static func select(_ targets: TranscriptWatchTargets) -> (paths: [String], cut: Int, uncovered: Bool) {
        var out: [String] = []
        var seen: Set<String> = []
        func add(_ path: String) { if seen.insert(path).inserted { out.append(path) } }
        let listed = Set(targets.paths)
        for path in targets.current { add(path) }
        for path in targets.current { add((path as NSString).deletingLastPathComponent) }
        for path in targets.current {
            let subagents = ((path as NSString).deletingPathExtension as NSString).appendingPathComponent("subagents")
            if listed.contains(subagents) { add(subagents) }
        }
        for path in targets.paths {
            let name = (path as NSString).lastPathComponent
            let agentFile = name.hasPrefix("agent-") || name.hasPrefix("rollout-")
            if agentFile, let id = fileID(path), targets.running.contains(id) { add(path) }
        }
        let kept = Array(out.prefix(maxSources))
        let listedAgents = Set(targets.paths.compactMap { path -> String? in
            let name = (path as NSString).lastPathComponent
            guard name.hasSuffix(".jsonl"), name.hasPrefix("agent-") || name.hasPrefix("rollout-") else { return nil }
            return fileID(path)
        })
        return (kept, out.count - kept.count, !targets.mustCover.isSubset(of: listedAgents))
    }

    private func apply() {
        let (wanted, cut, uncovered) = Self.select(targets)
        let wantedSet = Set(wanted)
        for path in sources.keys where !wantedSet.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        var opened = false
        var failed = cut > 0 || uncovered
        if cut > 0 { Self.log.notice("Workchat watch: \(cut) paths over the \(Self.maxSources)-source cap, reading every 3 s too") }
        if uncovered, !loggedUncovered {
            Self.log.notice("Workchat watch: a running agent has no transcript to watch yet, reading every 3 s too")
        }
        loggedUncovered = uncovered
        for path in wanted where sources[path] == nil {
            do {
                sources[path] = try fileEvents.open(path) { [weak self] event in
                    Self.onMain { self?.receive(event, at: path) }
                }
                opened = true
                loggedOpenFailures.remove(path)
            } catch {
                failed = true
                if loggedOpenFailures.insert(path).inserted {
                    let name = (path as NSString).lastPathComponent
                    let code = (error as? POSIXError)?.code.rawValue ?? -1
                    Self.log.notice("Workchat watch: cannot open \(name, privacy: .public) (errno \(code)), reading every 3 s")
                }
            }
        }
        openFailed = failed
        if wanted.isEmpty {
            if !loggedNoPaths {
                loggedNoPaths = true
                Self.log.notice("Workchat watch: the read listed no paths, reading every 3 s")
            }
        } else {
            loggedNoPaths = false
        }
        if opened { markDirty() } else { reschedule() }
    }

    private func receive(_ event: FileEvent, at path: String) {
        guard isRunning else { return }
        // A renamed or deleted file is no longer at its path: the next read's
        // `paths` reopens whatever is there now.
        if event == .replaced { sources.removeValue(forKey: path)?.cancel() }
        markDirty()
    }

    private func markDirty() {
        let now = clock.now
        lastEvent = now
        if dirtySince == nil { dirtySince = now }
        reschedule()
    }

    /// The one timer: the debounced change, the fallback tick, whichever is
    /// due first, never sooner than `minGap` after the last read.
    private func reschedule() {
        timer?.cancel(); timer = nil
        guard isRunning else { return }
        let now = clock.now
        var due: ContinuousClock.Instant?
        if let lastEvent, let dirtySince {
            due = min(lastEvent + timing.debounce, dirtySince + timing.minGap)
        }
        if isFallback {
            let since = fallbackSince ?? now
            fallbackSince = since
            let tick = max(lastRead ?? since, since) + timing.fallback
            due = due.map { min($0, tick) } ?? tick
        } else {
            fallbackSince = nil
        }
        guard var due else { return }
        if let lastRead { due = max(due, lastRead + timing.minGap) }
        timer = clock.schedule(at: due) { [weak self] in self?.fire() }
    }

    private func fire() {
        timer = nil
        lastRead = clock.now
        dirtySince = nil; lastEvent = nil
        onRefresh()
        reschedule()
    }

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "SessionFeed")

    /// The live source delivers on the main queue; another source's thread
    /// hops there first.
    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }
}

/// The live line's freshness on the Mac (spec C4, as on the phone): the
/// line goes out of date by the health of the watch behind it, not by the
/// age of the last read. Reads come on change only, so a long quiet tool
/// run has an old `observedAt` and is still current while the watch sees
/// every change.
package enum WorkchatLiveFreshness {
    /// `snapshot` observed at `now` while `watched`; as read otherwise. A
    /// snapshot without `observedAt` (unavailable) stays as it is.
    package static func effective(_ snapshot: SessionFeedLive?, watched: Bool, now: Date) -> SessionFeedLive? {
        guard watched, var shown = snapshot, shown.observedAt != nil else { return snapshot }
        shown.observedAt = now
        return shown
    }
}
