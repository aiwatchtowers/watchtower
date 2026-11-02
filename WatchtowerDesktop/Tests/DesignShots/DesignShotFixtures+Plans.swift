import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Synthetic snapshots rendered by the same production content as the live screen.
@MainActor
enum PlansShotFixtures {
    enum State: String, CaseIterable {
        case filled, empty, loading, error, readError, busy, scoped, unavailable, unknownID, stale, disabled
        case collecting, idle, hit, expired, predictionExpired, missingSession
    }
    static let now = Date(timeIntervalSince1970: 1_792_314_000)

    static func snapshot(_ provider: PlanUsageProvider, state: State = .filled) -> PlanUsageStatus {
        let isClaude = provider == .claude
        let percent = state == .idle ? 0.0 : state == .hit ? 100.0 : isClaude ? 76.0 : 42.0
        let published = state == .predictionExpired ? now.addingTimeInterval(-300) :
            state == .stale || state == .error ? now.addingTimeInterval(-1080) : now
        let reset = published.addingTimeInterval(isClaude ? 48 * 3600 : 53 * 3600)
        let hit = state == .predictionExpired ? now.addingTimeInterval(-1) : published.addingTimeInterval(isClaude ? 32 * 3600 : 232 * 3600)
        let key = isClaude ? "weekly_all" : "codex:secondary:10080"
        let rawState = state == .collecting || (state == .unknownID && !isClaude) ? "collecting" :
            state == .idle ? "idle" : state == .hit ? "hit" :
            isClaude || state == .predictionExpired ? "will_hit" : "safe"
        let projected = rawState == "safe" || rawState == "will_hit"
        let rate = state == .predictionExpired ? (isClaude ? 288.96321070234 : 698.32775919732) : (isClaude ? 0.75 : 0.25)
        let expiredReset = state == .expired ? now : reset
        let weekly = PlanUsageLimit(key: key, label: "Weekly", group: "weekly", percent: percent,
                                    resetsAt: expiredReset, severity: nil,
                                    projection: PlanUsageProjection(state: rawState, hitAt: projected ? hit : nil,
                                                                    ratePerHour: projected ? rate : 0),
                                    windowDurationMinutes: 10080)
        let session = PlanUsageLimit(key: isClaude ? "session" : "codex:primary:300", label: "5-hour window", group: "session",
                                     percent: isClaude ? 38 : 17, resetsAt: published.addingTimeInterval(2.25 * 3600), severity: nil,
                                     projection: PlanUsageProjection(state: "collecting", hitAt: nil, ratePerHour: 0), windowDurationMinutes: 300)
        let extra = PlanUsageLimit(key: isClaude ? "weekly_scoped:sonnet" : "review:primary:300",
                                   label: isClaude ? "Weekly · Sonnet" : "Review quota · 5 hours", group: isClaude ? "weekly" : "session",
                                   percent: isClaude ? 12 : 86, resetsAt: isClaude ? reset : published.addingTimeInterval(12000), severity: nil,
                                   projection: PlanUsageProjection(state: "collecting", hitAt: nil, ratePerHour: 0),
                                   windowDurationMinutes: isClaude ? 10080 : 300)
        let values = isClaude ? [3.0, 9, 12, 12, 22, 28, 29, 29, 35, 39, 47, 51, 64, 71, percent] :
            [1.0, 2, 4, 7, 9, 11, 11, 17, 19, 23, 26, 31, 32, 38, percent]
        let start = reset.addingTimeInterval(-7 * 86400)
        var history = values.enumerated().map { index, value in
            PlanUsageSample(takenAt: start.addingTimeInterval(published.timeIntervalSince(start) * Double(index) / 14),
                            percent: min(value, percent), resetsAt: expiredReset)
        }
        if state == .collecting {
            history = [PlanUsageSample(takenAt: published.addingTimeInterval(-300), percent: percent - 2, resetsAt: expiredReset),
                       PlanUsageSample(takenAt: published, percent: percent, resetsAt: expiredReset)]
        } else if state == .idle { history = [] }
        let identityKnown = isClaude || (state != .unknownID && state != .error)
        let line: PlanUsageLine? = !projected || state == .expired || !identityKnown ? nil :
            PlanUsageLine(startAt: published, startPercent: percent, endAt: isClaude || state == .predictionExpired ? hit : reset,
                          endPercent: isClaude || state == .predictionExpired ? 100 : 55.25)
        let limits = state == .missingSession ? [weekly, extra].filter { $0.windowDurationMinutes != 300 } : [weekly, session, extra]
        // Retained candidates are present even when the current freshness gate hides them.
        let plot = PlanUsagePlot(fetchedAt: published, limits: [key: line])
        var samples = [key: history]
        for limit in [session, extra] {
            samples[limit.key] = [PlanUsageSample(takenAt: published, percent: limit.percent, resetsAt: limit.resetsAt)]
        }
        if !identityKnown { samples = [:] }
        return PlanUsageStatus(state: state == .error ? "error" : state == .disabled ? "disabled" : "ok",
                               reason: state == .error ? "network" : "", plan: isClaude ? "Max" : "Plus", fetchedAt: published,
                               lastError: "", limits: limits,
                               breakdown: isClaude ? [PlanUsageBreakdownRow(key: "code", label: "Claude Code", percent: 82),
                                                      PlanUsageBreakdownRow(key: "chats", label: "Chats", percent: 14),
                                                      PlanUsageBreakdownRow(key: "cowork", label: "Cowork", percent: 4)] : [],
                               provider: provider,
                               identityKnown: identityKnown, plot: plot, history: samples)
    }

    static func model(_ state: State = .filled) -> PlansScreenPresentation {
        let noData = state == .empty || state == .loading || state == .readError
        let claude = noData || state == .scoped ? nil : snapshot(.claude, state: state == .error || state == .unavailable ? .filled : state)
        let codex = noData || state == .unavailable ? nil : snapshot(.codex, state: state)
        let errors: [PlanUsageProvider: PlansOperationError]
        if state == .readError {
            errors = [.claude: PlansOperationError(code: "storage"), .codex: PlansOperationError(code: "storage")]
        } else {
            errors = state == .error || state == .unavailable ? [.codex: PlansOperationError(code: "network")] : [:]
        }
        return PlansScreenPresentation(claude: claude, codex: codex, errors: errors,
                                       refreshing: state == .busy || state == .loading ? Set(PlanUsageProvider.allCases) : [],
                                       now: now, enabled: state != .disabled)
    }

    static func screen(_ state: State = .filled) -> AnyView {
        AnyView(VStack(spacing: 0) {
            UsageTabs(selection: .constant(.plan))
            PlansContent(model: model(state), period: .constant(state == .missingSession ? .session : .weekly), showInMenuBar: .constant(true),
                         refresh: { _ in }, refreshAll: {})
        }.detailBackground())
    }

    static var shots: [DesignShot] {
        State.allCases.map { state in
            DesignShot(name: "plans-\(state.rawValue)", size: NSSize(width: 1120, height: 1340)) { screen(state) }
        } + [DesignShot(name: "plans-narrow", size: NSSize(width: 620, height: 2100)) { screen() }] + menuShots
    }

    static var menuShots: [DesignShot] {
        [State.filled, .empty, .loading, .error, .busy, .scoped, .unknownID, .stale, .disabled].map { state in
            DesignShot(name: "plans-menu-\(state.rawValue)", size: NSSize(width: 1120, height: 520)) {
                menuScreen(state, show: state != .disabled)
            }
        } + [
            DesignShot(name: "plans-menu-off", size: NSSize(width: 1120, height: 520)) { menuScreen(.filled, show: false) },
            DesignShot(name: "plans-menu-narrow", size: NSSize(width: 620, height: 90)) { menuScreen(.filled, barOnly: true) }
        ]
    }

    static func menuScreen(_ state: State, show: Bool = true, barOnly: Bool = false) -> AnyView {
        let model = model(state)
        let label = (try? PlansPresentation.menuBar(claude: model.providers[0].status,
                                                    codex: model.providers[1].status, show: show, now: now)) ?? ""
        return AnyView(VStack(alignment: .leading, spacing: Spacing.large) {
            Text(label).font(.caption).monospacedDigit()
            if !barOnly { PlansTrayRows(lines: trayLines(model)) {} }
            Spacer()
        }.padding(Spacing.page).frame(maxWidth: .infinity, alignment: .leading).detailBackground())
    }

    static func trayLines(_ model: PlansScreenPresentation) -> [String] {
        model.providers.compactMap(\.status).flatMap { (try? PlansPresentation.tray($0, now: now)) ?? [] }
    }
}
