import Foundation
import os

/// The steps between opening a Workchat pane and its first feed paint.
package enum WorkchatOpenPhase: String, CaseIterable {
    case appear, spawn, exit, decode, adapter, paint
}

/// Times one open of a Workchat pane: each phase is a signpost interval
/// (subsystem `com.watchtower.desktop`, category `WorkchatOpen`, named after
/// the phase) and, at the first paint, one log line with the gap since the
/// previous phase in ms. Only the first mark of a phase counts, so the poll's
/// later reads and re-renders never move the numbers. In memory only.
@MainActor
package final class WorkchatOpenTrace {
    private static let signposter = OSSignposter(subsystem: "com.watchtower.desktop", category: "WorkchatOpen")
    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "WorkchatOpen")

    private let sessionID: Int64
    private let reopen: Bool
    private let clock: () -> ContinuousClock.Instant
    private var marks: [WorkchatOpenPhase: ContinuousClock.Instant] = [:]
    private var interval: (state: OSSignpostIntervalState, phase: WorkchatOpenPhase)?
    private var reported: String?

    package init(sessionID: Int64, reopen: Bool, clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.sessionID = sessionID
        self.reopen = reopen
        self.clock = clock
    }

    /// The log line, once the first paint was marked.
    package var report: String? { reported }

    package func mark(_ phase: WorkchatOpenPhase) {
        // Once the report is out the open is over: a later poll must not start
        // an interval that nothing closes.
        guard reported == nil, marks[phase] == nil else { return }
        marks[phase] = clock()
        let signposter = Self.signposter
        if let interval { signposter.endInterval(Self.name(interval.phase), interval.state) }
        interval = phase == .paint ? nil : (signposter.beginInterval(Self.name(phase), id: signposter.makeSignpostID()), phase)
        guard phase == .paint else { return }
        let line = makeReport()
        reported = line
        Self.log.notice("\(line, privacy: .public)")
    }

    /// Gaps in enum order; a phase that never happened (a kept store paints
    /// before any read) prints `-` and the next figure spans the hole.
    private func makeReport() -> String {
        var parts: [String] = []
        var previous: ContinuousClock.Instant?
        var first: ContinuousClock.Instant?
        for phase in WorkchatOpenPhase.allCases {
            guard let at = marks[phase] else {
                if phase != .appear { parts.append("\(Self.label(phase))=-") }
                continue
            }
            if let previous, phase != .appear {
                parts.append("\(Self.label(phase))=\(Self.ms(at - previous))")
            }
            first = first ?? at
            previous = at
        }
        let total = first.flatMap { start in marks[.paint].map { Self.ms($0 - start) } } ?? 0
        let kind = reopen ? "reopen" : "first"
        return (["workchat open session=\(sessionID) \(kind) total=\(total)ms"] + parts).joined(separator: " ")
    }

    private static func label(_ phase: WorkchatOpenPhase) -> String { phase == .exit ? "cli" : phase.rawValue }

    private static func ms(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }

    private static func name(_ phase: WorkchatOpenPhase) -> StaticString {
        switch phase {
        case .appear: "appear"
        case .spawn: "spawn"
        case .exit: "exit"
        case .decode: "decode"
        case .adapter: "adapter"
        case .paint: "paint"
        }
    }
}
