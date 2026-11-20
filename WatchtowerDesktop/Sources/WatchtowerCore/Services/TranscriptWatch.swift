import Combine
import Foundation
import os

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

/// The live clock: main-queue timers.
package struct MainQueueWatchClock: TranscriptWatchClock {
    package nonisolated init() {}

    package var now: ContinuousClock.Instant { .now }

    package func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        let delay = max(.zero, ContinuousClock.now.duration(to: deadline)).components
        let seconds = Double(delay.seconds) + Double(delay.attoseconds) / 1e18
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return AnyCancellable { item.cancel() }
    }
}

/// Asks for a Workchat read when a file the last read listed (`paths` of
/// `workbench session-feed --json`) changes, instead of a 3 s poll (spec
/// `2026-11-20-phone-workchat-live-design.md` §8). One source per path, at
/// most `maxSources`; a finished subagent's files are not watched. A read
/// is asked for `debounce` after the last event, at most once per `minGap`
/// while events keep coming (a burst never starves it). Only when a path
/// cannot be opened, or the read listed none (a session whose transcript
/// does not exist yet), it falls back to a read every `fallbackInterval`.
@MainActor
package final class TranscriptWatch {
    package static let debounce: Duration = .milliseconds(250)
    package static let minGap: Duration = .seconds(1)
    package static let fallbackInterval: Duration = .seconds(3)
    package static let maxSources = 32

    private let fileEvents: FileEventSource
    private let clock: TranscriptWatchClock
    private let onRefresh: @MainActor () -> Void
    private var sources: [String: any Cancellable] = [:]
    /// The first unanswered event and the last one; nil when clean.
    private var dirtySince: ContinuousClock.Instant?
    private var lastEvent: ContinuousClock.Instant?
    private var lastRefresh: ContinuousClock.Instant?
    private var timer: (any Cancellable)?
    private var fallback: (any Cancellable)?
    private var loggedFallback = false

    package init(fileEvents: FileEventSource, clock: TranscriptWatchClock, onRefresh: @escaping @MainActor () -> Void) {
        self.fileEvents = fileEvents
        self.clock = clock
        self.onRefresh = onRefresh
    }

    /// The paths with an open source.
    package var watchedPaths: Set<String> { Set(sources.keys) }
    /// Reads come from the fallback timer.
    package var isFallback: Bool { fallback != nil }

    /// Follows the paths of the last read: a path no longer listed (or a
    /// finished agent's) is closed, a new one opened; an open source is kept.
    /// `finishedAgents` are agent ids; a path whose file name carries one is
    /// a finished subagent's transcript, sidecar or Codex rollout.
    package func update(paths: [String], finishedAgents: Set<String>) {
        let wanted = Self.select(paths, finishedAgents: finishedAgents)
        let wantedSet = Set(wanted)
        for path in sources.keys where !wantedSet.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        var failed = wanted.isEmpty
        for path in wanted where sources[path] == nil {
            do {
                sources[path] = try fileEvents.open(path) { [weak self] event in
                    Self.onMain { self?.receive(event, at: path) }
                }
            } catch {
                failed = true
            }
        }
        setFallback(failed)
    }

    /// Closes every source and timer.
    package func stop() {
        for source in sources.values { source.cancel() }
        sources = [:]
        timer?.cancel(); timer = nil
        fallback?.cancel(); fallback = nil
        dirtySince = nil; lastEvent = nil
    }

    /// The paths to watch, at most `maxSources`: conversation transcripts
    /// first (the newest, listed last, before older ones), then directories
    /// (new subagent files), then the rest (running subagents' transcripts and
    /// sidecars).
    package static func select(_ paths: [String], finishedAgents: Set<String>) -> [String] {
        let finished = finishedAgents.filter { !$0.isEmpty }
        func tier(_ path: String) -> Int {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix("agent-") { return 2 }
            if (name as NSString).pathExtension == "jsonl" { return 0 }
            return (name as NSString).pathExtension.isEmpty ? 1 : 2
        }
        let kept = paths.enumerated().filter { _, path in
            let name = (path as NSString).lastPathComponent
            return !finished.contains { name.contains($0) }
        }
        let ranked = kept.sorted { lhs, rhs in
            let (lt, rt) = (tier(lhs.element), tier(rhs.element))
            if lt != rt { return lt < rt }
            return lt == 0 ? lhs.offset > rhs.offset : lhs.offset < rhs.offset
        }
        return ranked.prefix(maxSources).map(\.element)
    }

    private func receive(_ event: FileEvent, at path: String) {
        // A renamed or deleted file is no longer at its path: the next read's
        // `paths` reopens whatever is there now.
        if event == .replaced { sources.removeValue(forKey: path)?.cancel() }
        let now = clock.now
        lastEvent = now
        if dirtySince == nil { dirtySince = now }
        schedule()
    }

    private func schedule() {
        guard let lastEvent, let dirtySince else { return }
        var due = min(lastEvent + Self.debounce, dirtySince + Self.minGap)
        if let lastRefresh { due = max(due, lastRefresh + Self.minGap) }
        timer?.cancel()
        timer = clock.schedule(at: due) { [weak self] in self?.fire() }
    }

    private func fire() {
        timer = nil; dirtySince = nil; lastEvent = nil
        lastRefresh = clock.now
        onRefresh()
    }

    private func setFallback(_ on: Bool) {
        guard on else { fallback?.cancel(); fallback = nil; return }
        guard fallback == nil else { return }
        if !loggedFallback {
            loggedFallback = true
            Self.log.notice("Workchat watch: a path cannot be watched, reading every 3 s")
        }
        armFallback()
    }

    private func armFallback() {
        fallback = clock.schedule(at: clock.now + Self.fallbackInterval) { [weak self] in
            guard let self, fallback != nil else { return }
            lastRefresh = clock.now
            armFallback()
            onRefresh()
        }
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
