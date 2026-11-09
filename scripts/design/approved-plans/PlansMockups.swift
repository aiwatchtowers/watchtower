import AppKit
import SwiftUI
import DesignKit

/// Design proposal only. No provider requests or live-install values.
struct PlansMockupModel {
    enum State: String, CaseIterable { case filled, empty, loading, error, busy, scoped, unavailable }
    struct Projection {
        enum Status { case idle, collecting, safe, willHit, hit, stale }
        let status: Status
        let headline: String
        let detail: String
        let hitAt: Date?
        let ratePerHour: Double
        let endPercent: Double?
        var drawsForecast: Bool { status == .safe || status == .willHit }
        var isWarning: Bool { status == .willHit || status == .hit || status == .stale }
        static let collecting = Self(status: .collecting, headline: "Learning your pace…",
            detail: "At least 15 minutes of samples are needed.", hitAt: nil, ratePerHour: 0, endPercent: nil)
        static let hit = Self(status: .hit, headline: "Limit reached",
            detail: "Capacity returns when this window resets.", hitAt: nil, ratePerHour: 0, endPercent: nil)
        static let idle = Self(status: .idle, headline: "Window hasn’t started",
            detail: "A forecast will appear after the window starts.", hitAt: nil, ratePerHour: 0, endPercent: nil)
        static let stale = Self(status: .stale, headline: "Forecast unavailable",
            detail: "Refresh Codex to get an up-to-date projection.", hitAt: nil, ratePerHour: 0, endPercent: nil)
    }
    /// Fixed, synthetic timestamps. Forecast endpoints are model values, never inferred by the view.
    static let now = ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z")!
    struct Provider: Identifiable {
        let name: String
        let plan: String
        let used: Int
        let shortUsed: Int
        let reset: String
        let shortReset: String
        let note: String
        let tone: String
        let samples: [Double]
        let windowStart: Date
        let resetsAt: Date
        let projection: Projection
        let startLabel: String
        let resetLabel: String
        var sampleTimes: [Date] {
            samples.indices.map { windowStart.addingTimeInterval(Self.interval(windowStart, PlansMockupModel.now) * Double($0) / Double(samples.count - 1)) }
        }
        private static func interval(_ from: Date, _ to: Date) -> TimeInterval { to.timeIntervalSince(from) }
        var id: String { name }
    }
    let state: State
    let title = "Plans & limits"
    let subtitle = "Your subscriptions, in one place."
    let tabs = ["Plans", "Watchtower", "Progress", "Usage"]
    let refresh = "Refresh"
    let busyAction = "Refreshing…"
    let tabsLabel = "Statistics"
    let scopeTitle = "Other Claude limits"
    let scopedLimit = "Weekly · Sonnet"
    let scopedValue = "12% used"
    let surfaceTitle = "Claude usage by surface"
    let surfaces = [("Claude Code", "82%"), ("Chats", "14%"), ("Cowork", "4%")]
    let unavailableTitle = "Codex limits unavailable"
    let unavailableDetail = "Your Codex allowance couldn’t be read. Claude is still up to date."
    let unavailableAction = "Retry Codex"
    let week = "Weekly usage"
    let session = "5-hour window"
    let usedLabel = "used"
    let axes = ["100%", "50%", "0%"]
    let periods = ["Weekly", "5 hours"]
    let periodTitle = "Limit window"
    let stale = "Updated 18 minutes ago · refresh failed"
    let history = "This week"
    let historyNote = "Solid: usage so far · Dashed: forecast at your current pace"
    let nowLabel = "Now"
    let resetLabel = "Reset"
    let hitLabel = "100% reached · Mon 17:00"
    let chartDates = ["Oct 12", "Oct 14", "Oct 16", "Now"]
    let footer = "Subscription percentages are tracked separately. API costs live in Watchtower."
    let menu = "Show limits in the menu bar"
    let available = "Available capacity"
    let availableNote = "Weekly allowance remaining in each subscription"
    let refreshing: String
    let message: String
    let detail: String
    let action: String
    let providers: [Provider]

    init(_ state: State) {
        self.state = state
        refreshing = state == .busy ? "Refreshing both providers…" : state == .error || state == .unavailable ? "Some providers need attention" : "Updated just now"
        switch state {
        case .empty:
            message = "Bring your plans together"
            detail = "Connect Claude or Codex to see your limits and usage history here."
            action = "Connect a provider"
        case .loading:
            message = "Reading your plan limits…"
            detail = "Fetching the latest allowance from your connected providers."
            action = ""
        case .error:
            message = "Codex couldn’t refresh"
            detail = "Last updated 18 minutes ago. Claude is up to date. Codex values below may be out of date."
            action = "Retry"
        case .busy:
            message = "Refreshing your plans"
            detail = "Keeping the last known values visible while both providers update."
            action = ""
        case .scoped:
            message = "Showing Codex only"
            detail = "Claude isn’t connected. Connect it to compare both subscriptions here."
            action = "Connect Claude"
        case .unavailable:
            message = "Claude is up to date"
            detail = "Codex limits are unavailable. No estimate is shown in their place."
            action = "Retry Codex"
        case .filled:
            message = "Claude may run out before reset"
            detail = "At this pace, Claude reaches its weekly limit tomorrow. Codex is on track."
            action = ""
        }
        let claude = Provider(name: "Claude", plan: "Max", used: 76, shortUsed: 38,
            reset: "Resets Tue, 09:00 · in 2 days", shortReset: "Resets in 2h 15m", note: "24% weekly capacity left",
            tone: "purple", samples: [3, 9, 12, 12, 22, 28, 29, 29, 35, 39, 47, 51, 64, 71, 76],
            windowStart: Self.now.addingTimeInterval(-120 * 3600), resetsAt: Self.now.addingTimeInterval(48 * 3600),
            projection: Projection(status: .willHit, headline: "Limit in 1d 8h at this pace",
                detail: "Mon, 17:00 · 16h before reset", hitAt: Self.now.addingTimeInterval(32 * 3600),
                ratePerHour: 0.75, endPercent: 100), startLabel: "Oct 13", resetLabel: "Tue 09:00")
        let codex = Provider(name: "Codex", plan: "Connected", used: 42, shortUsed: 17,
            reset: "Resets Tue, 14:00 · in 2 days", shortReset: "Resets in 3h 40m", note: "58% weekly capacity left",
            tone: "teal", samples: [1, 2, 4, 7, 9, 11, 11, 17, 19, 23, 26, 31, 32, 38, 42],
            windowStart: Self.now.addingTimeInterval(-115 * 3600), resetsAt: Self.now.addingTimeInterval(53 * 3600),
            projection: state == .error ? .stale : Projection(status: .safe, headline: "On track to last until reset",
                detail: "About 55% used by Tue, 14:00", hitAt: Self.now.addingTimeInterval(232 * 3600),
                ratePerHour: 0.25, endPercent: 55.25), startLabel: "Oct 13", resetLabel: "Tue 14:00")
        providers = [.empty, .loading].contains(state) ? [] : state == .scoped ? [codex] : state == .unavailable ? [claude] : [claude, codex]
    }
}

@MainActor
enum PlansShotFixtures {
    static func screen(_ state: PlansMockupModel.State = .filled) -> AnyView {
        AnyView(PlansMockupView(model: PlansMockupModel(state)))
    }
    static var shots: [DesignShot] {
        PlansMockupModel.State.allCases.map { state in
            DesignShot(name: "plans-\(state.rawValue)", size: NSSize(width: 1120, height: 1230)) { screen(state) }
        } + [DesignShot(name: "plans-narrow", size: NSSize(width: 620, height: 1840)) { screen() }] + menuShots
    }
}

private struct PlansMockupView: View {
    let model: PlansMockupModel
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.wide) {
                    HStack {
                        KitSegmentedPicker(title: model.tabsLabel, selection: .constant("Plans"),
                            segments: model.tabs.map { KitSegment(value: $0, title: $0) })
                        Spacer()
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(model.title).font(.largeTitle.weight(.semibold))
                            Text(model.subtitle).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: Spacing.regular) {
                            Button(model.state == .busy ? model.busyAction : model.refresh, systemImage: "arrow.clockwise") {}
                                .buttonStyle(.kitSecondary).disabled(model.state == .busy)
                            Text(model.refreshing).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.state == .empty || model.state == .loading {
                        statusPage
                    } else {
                        status
                        providerGrid(width: geometry.size.width)
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: Spacing.small) {
                                Text(model.history).font(.title3.weight(.semibold))
                                Text(model.historyNote).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            KitSegmentedPicker(title: model.periodTitle, selection: .constant("Weekly"),
                                segments: model.periods.map { KitSegment(value: $0, title: $0) })
                        }
                        charts(width: geometry.size.width)
                        if model.state != .scoped { claudeDetails }
                        HStack {
                            Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                            Text(model.menu).font(.callout)
                            Spacer()
                            Toggle(model.menu, isOn: .constant(false)).labelsHidden().toggleStyle(.switch)
                        }.padding(Spacing.large).card()
                        Text(model.footer).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.wide)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }.detailBackground().controlSize(.small)
    }
    private var statusPage: some View {
        VStack(spacing: Spacing.large) {
            Image(systemName: model.state == .loading ? "arrow.triangle.2.circlepath" : "chart.xyaxis.line")
                .font(.largeTitle).foregroundStyle(Tone.status("teal"))
            Text(model.message).font(.title2.weight(.semibold))
            Text(model.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.action.isEmpty { Button(model.action) {}.buttonStyle(.kitPrimary) }
        }.padding(Spacing.hero).frame(maxWidth: .infinity, minHeight: 380).card()
    }
    private var status: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: (model.state == .error || model.state == .filled || model.state == .unavailable) ? "exclamationmark.triangle" : model.state == .busy ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .foregroundStyle((model.state == .error || model.state == .filled || model.state == .unavailable) ? Tone.warning : Tone.success)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(model.message).font(.callout.weight(.semibold))
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !model.action.isEmpty { Button(model.action) {}.buttonStyle(.kitSecondary) }
        }.padding(Spacing.large).background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }
    private func providerGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: columns(width), spacing: Spacing.large) {
            ForEach(model.providers) { provider in providerCard(provider) }
            if model.state == .unavailable {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    Text(model.unavailableTitle).font(.headline)
                    Text(model.unavailableDetail).foregroundStyle(.secondary)
                    Button(model.unavailableAction) {}.buttonStyle(.kitSecondary)
                }.padding(Spacing.page).frame(maxWidth: .infinity, minHeight: 220, alignment: .leading).card()
            }
        }
    }
    private func columns(_ width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.large), count: width < 800 ? 1 : 2)
    }
    private func providerCard(_ p: PlansMockupModel.Provider) -> some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack {
                Image(systemName: p.name == "Claude" ? "sparkle" : "terminal")
                    .foregroundStyle(Tone.status(p.tone))
                Text(p.name).font(.headline)
                Text(p.plan).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(model.state == .error && p.name == "Codex" ? Tone.warning : Tone.success)
                    .frame(width: IconSize.stateDot, height: IconSize.stateDot)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text("\(p.used)%").font(.largeTitle.weight(.semibold)).monospacedDigit()
                Text(model.usedLabel).foregroundStyle(.secondary)
                Spacer()
                Text(model.week).font(.caption).foregroundStyle(.secondary)
            }
            bar(p.used, tone: p.tone)
            Text(p.reset).font(.caption).foregroundStyle(.secondary)
            if model.state == .error && p.name == "Codex" {
                Text(model.stale).font(.caption).foregroundStyle(Tone.warning)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label(p.projection.headline, systemImage: p.projection.isWarning ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(p.projection.isWarning ? Tone.warning : Tone.success)
                Text(p.projection.detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(model.session).font(.caption).foregroundStyle(.secondary)
                    Text(p.shortReset).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(p.shortUsed)%").font(.title3.weight(.medium)).monospacedDigit()
            }.padding(Spacing.medium).background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
        }.padding(Spacing.page).card()
    }
    private func bar(_ value: Int, tone: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Fill.hover)
                Capsule().fill(Tone.status(tone)).frame(width: proxy.size.width * Double(value) / 100)
            }
        }.frame(height: 6)
    }
    private func charts(width: CGFloat) -> some View {
        LazyVGrid(columns: columns(width), spacing: Spacing.large) {
            ForEach(model.providers) { p in
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    HStack {
                        Circle().fill(Tone.status(p.tone)).frame(width: IconSize.stateDot, height: IconSize.stateDot)
                        Text(p.name).font(.callout.weight(.medium))
                        Spacer()
                        Text("\(p.used)%").font(.callout.weight(.semibold)).monospacedDigit()
                    }
                    HStack(spacing: Spacing.regular) {
                        PlansChart(provider: p, nowLabel: model.nowLabel).frame(height: 142)
                        VStack { Text(model.axes[0]); Spacer(); Text(model.axes[1]); Spacer(); Text(model.axes[2]) }
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    HStack {
                        Text(p.startLabel)
                        Spacer()
                        Text("\(model.resetLabel) · \(p.resetLabel)")
                    }.font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: p.projection.isWarning ? "exclamationmark.triangle" : "checkmark.circle")
                        Text(p.projection.status == .willHit ? model.hitLabel : p.projection.headline)
                    }.font(.caption).foregroundStyle(p.projection.isWarning ? Tone.warning : Tone.success)
                }.padding(Spacing.page).card()
            }
        }
    }
    private var claudeDetails: some View {
        HStack(alignment: .top, spacing: Spacing.wide) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(model.scopeTitle).font(.headline)
                Text(model.scopedLimit).font(.caption).foregroundStyle(.secondary)
                Text(model.scopedValue).font(.callout)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(model.surfaceTitle).font(.headline)
                ForEach(model.surfaces, id: \.0) { name, value in
                    HStack { Text(name); Spacer(); Text(value).monospacedDigit() }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(Spacing.page).card()
    }
    private var capacity: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(model.available).font(.headline)
            Text(model.availableNote).font(.caption).foregroundStyle(.secondary)
            ForEach(model.providers) { p in
                HStack(spacing: Spacing.medium) {
                    Text(p.name).font(.callout).frame(width: 64, alignment: .leading)
                    bar(100 - p.used, tone: p.tone)
                    Text("\(100 - p.used)%").font(.callout.weight(.medium)).monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }
        }.padding(Spacing.page).card()
    }
}

private struct PlansChart: View {
    let provider: PlansMockupModel.Provider
    let nowLabel: String
    var body: some View {
        Canvas { context, size in
            let p = provider
            let duration = p.resetsAt.timeIntervalSince(p.windowStart)
            // Leave room for the 100% endpoint marker inside the canvas.
            let inset: CGFloat = 5
            func point(_ date: Date, _ percent: Double) -> CGPoint {
                CGPoint(x: inset + (size.width - 2 * inset) * date.timeIntervalSince(p.windowStart) / duration,
                        y: inset + (size.height - 2 * inset) * (1 - percent / 100))
            }
            for fraction in [0.0, 0.5, 1.0] {
                var line = Path()
                line.move(to: CGPoint(x: inset, y: inset + (size.height - 2 * inset) * fraction))
                line.addLine(to: CGPoint(x: size.width - inset, y: inset + (size.height - 2 * inset) * fraction))
                context.stroke(line, with: .color(Fill.hover), lineWidth: Stroke.hairline)
            }
            let now = point(PlansMockupModel.now, 0).x
            var nowLine = Path()
            nowLine.move(to: CGPoint(x: now, y: inset))
            nowLine.addLine(to: CGPoint(x: now, y: size.height - inset))
            context.stroke(nowLine, with: .color(.secondary), style: StrokeStyle(lineWidth: Stroke.hairline, dash: [2, 4]))
            context.draw(Text(nowLabel).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: now - 4, y: inset + 6), anchor: .topTrailing)
            let reset = size.width - inset
            var resetLine = Path()
            resetLine.move(to: CGPoint(x: reset, y: inset))
            resetLine.addLine(to: CGPoint(x: reset, y: size.height - inset))
            context.stroke(resetLine, with: .color(.secondary), lineWidth: Stroke.hairline)
            var path = Path()
            for (index, value) in p.samples.enumerated() {
                let position = point(p.sampleTimes[index], value)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            var fill = path
            fill.addLine(to: point(PlansMockupModel.now, 0))
            fill.addLine(to: point(p.windowStart, 0))
            fill.closeSubpath()
            context.fill(fill, with: .color(Tone.status(p.tone).opacity(Fill.cardOpacity)))
            context.stroke(path, with: .color(Tone.status(p.tone)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if p.projection.drawsForecast, let percent = p.projection.endPercent,
               let endpoint = p.projection.status == .willHit ? p.projection.hitAt : p.resetsAt {
                let end = point(endpoint, percent)
                var forecast = Path()
                forecast.move(to: point(PlansMockupModel.now, Double(p.used)))
                forecast.addLine(to: end)
                let color = p.projection.status == .willHit ? Tone.warning : Tone.status(p.tone)
                context.stroke(forecast, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)), with: .color(color))
            }
        }
    }
}

/// Menu design proposal. Selection policy awaits the owner's decision.
struct PlansMenuMockupModel {
    enum State: String, CaseIterable { case filled, empty, loading, error, busy, scoped, unknownID = "unknown-id", stale, off }
    enum Policy: String { case worst, base, all }
    struct Quota: Identifiable {
        let key: String
        let bucket: String
        let window: String
        let used: Int
        let forecast: String
        let reset: String
        let hitInMinutes: Int?
        var id: String { key }
    }
    let state: State
    let policy: Policy
    let app = "Watchtower"
    let menuItems = ["File", "Edit", "View", "Window", "Help"]
    let clock = "Mon 09:41"
    let title = "Plans & limits"
    let claude = "Claude"
    let codex = "Codex"
    let claudePlan = "Max"
    let claudeQuota = "5h 38% · 7d 76%"
    let claudeForecast = "Weekly limit tomorrow · 16h before reset"
    let baseBucket = "Codex"
    let extraBucket = "Review quota"
    let open = "Open Plans"
    let refresh = "Refresh"
    let retry = "Retry Codex"
    let toggle = "Show limits in the menu bar"
    let updated = "Updated just now"
    let selectedLabel = "In menu bar"
    let noForecast = "Current values only · forecast unavailable"
    let loadingCopy = "Reading connected plans…"
    let busyCopy = "Refreshing both providers…"
    let errorCopy = "Codex couldn’t refresh. Retry to read current limits."
    let staleCopy = "Codex is out of date. Its menu-bar numbers are hidden."
    let emptyCopy = "No plan limits available. Sign in to Claude or Codex, then refresh."
    let offCopy = "Menu-bar numbers are off. Plans are still available here."
    let policyNote: String
    let quotas: [Quota]
    var hasClaude: Bool { ![.empty, .loading, .scoped].contains(state) }
    var hasCodex: Bool { ![.empty, .loading, .error, .stale].contains(state) }
    var selectedQuota: Quota? {
        guard hasCodex else { return nil }
        if policy == .base { return quotas.filter { $0.bucket == baseBucket }.max { $0.used < $1.used } }
        return quotas.sorted {
            if ($0.used >= 100) != ($1.used >= 100) { return $0.used >= 100 }
            let left = state == .unknownID ? nil : $0.hitInMinutes
            let right = state == .unknownID ? nil : $1.hitInMinutes
            if (left != nil) != (right != nil) { return left != nil }
            if let left, let right, left != right { return left < right }
            if $0.used != $1.used { return $0.used > $1.used }
            return $0.key < $1.key
        }.first
    }
    var barText: String {
        guard state != .off else { return "" }
        var parts: [String] = []
        if hasClaude { parts.append("\(claude) \(claudeQuota)") }
        if hasCodex {
            if policy == .all {
                parts.append(codex + " " + quotas.map { "\($0.bucket) \($0.window) \($0.used)%" }.joined(separator: " · "))
            } else if let quota = selectedQuota {
                parts.append("\(codex) \(quota.window) \(quota.used)%")
            }
        }
        let warning = hasClaude || (state != .unknownID && selectedQuota?.hitInMinutes != nil)
        return (warning && !parts.isEmpty ? "⚠︎ " : "") + parts.joined(separator: "  |  ")
    }
    var freshness: String {
        switch state {
        case .empty: "Not connected"
        case .loading: "Loading…"
        case .busy: busyCopy
        case .error, .stale: "Needs attention"
        default: updated
        }
    }
    var stateCopy: String? {
        switch state {
        case .empty: emptyCopy
        case .loading: loadingCopy
        case .error: errorCopy
        case .busy: busyCopy
        case .unknownID: noForecast
        case .stale: staleCopy
        case .off: offCopy
        default: nil
        }
    }
    init(_ state: State = .filled, policy: Policy = .worst) {
        self.state = state
        self.policy = policy
        switch policy {
        case .worst: policyNote = "Draft · most restrictive Codex quota (recommended)"
        case .base: policyNote = "Alternative · base bucket only misses the tighter Review quota"
        case .all: policyNote = "Alternative · every quota in the bar takes much more space"
        }
        quotas = [
            Quota(key: "codex:5h", bucket: "Codex", window: "5h", used: 17, forecast: "On track until reset", reset: "Resets in 3h 40m", hitInMinutes: nil),
            Quota(key: "codex:7d", bucket: "Codex", window: "7d", used: 42, forecast: "On track until reset", reset: "Resets Tue, 14:00", hitInMinutes: nil),
            Quota(key: "review:5h", bucket: "Review quota", window: "5h", used: 86, forecast: "Limit in 55m · before the reset", reset: "Resets in 3h 20m", hitInMinutes: 55)
        ]
    }
}

extension PlansShotFixtures {
    static var menuShots: [DesignShot] {
        PlansMenuMockupModel.State.allCases.map { state in
            DesignShot(name: "plans-menu-\(state.rawValue)", size: NSSize(width: 1120, height: 760)) {
                AnyView(PlansMenuMockupView(model: PlansMenuMockupModel(state)))
            }
        } + [
            DesignShot(name: "plans-menu-narrow", size: NSSize(width: 620, height: 760)) {
                AnyView(PlansMenuMockupView(model: PlansMenuMockupModel(), compactContext: true))
            },
            DesignShot(name: "plans-menu-policy-base", size: NSSize(width: 1120, height: 760)) {
                AnyView(PlansMenuMockupView(model: PlansMenuMockupModel(policy: .base)))
            },
            DesignShot(name: "plans-menu-policy-all", size: NSSize(width: 1120, height: 760)) {
                AnyView(PlansMenuMockupView(model: PlansMenuMockupModel(policy: .all)))
            }
        ]
    }
}

private struct PlansMenuMockupView: View {
    let model: PlansMenuMockupModel
    var compactContext = false
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack(spacing: Spacing.large) {
                Image(systemName: "apple.logo")
                Text(model.app).fontWeight(.semibold).fixedSize()
                if !compactContext {
                    HStack(spacing: Spacing.large) { ForEach(model.menuItems, id: \.self) { Text($0) } }.fixedSize()
                }
                Spacer(minLength: Spacing.medium)
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                    if !model.barText.isEmpty { Text(model.barText).lineLimit(1).truncationMode(.middle).monospacedDigit()
                            .fixedSize(horizontal: model.policy != .all, vertical: false) }
                }.layoutPriority(1).padding(.horizontal, Spacing.regular).padding(.vertical, Spacing.compact)
                    .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.control))
                Text(model.clock).fixedSize()
            }.font(.caption).padding(.horizontal, Spacing.large).frame(height: Spacing.wide + Spacing.regular).panelBackground()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text(model.title).font(.title2.weight(.semibold))
                    Text(model.policyNote).font(.caption).foregroundStyle(.secondary)
                }.padding(Spacing.page)
                Spacer(minLength: 0)
                popup.padding(.trailing, Spacing.large)
            }
            Spacer(minLength: 0)
        }.detailBackground().controlSize(.small)
    }
    private var popup: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack {
                Text(model.title).font(.headline)
                Spacer()
                Text(model.freshness).font(.caption2).foregroundStyle(.secondary)
            }
            if let text = model.stateCopy {
                Text(text).font(.caption).foregroundStyle(model.state == .error || model.state == .stale ? Tone.warning : Tone.status("gray"))
            }
            if model.hasClaude {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    HStack { Text(model.claude).font(.headline); Text(model.claudePlan).foregroundStyle(.secondary); Spacer(); Text(model.claudeQuota).monospacedDigit() }
                    Text(model.claudeForecast).font(.caption).foregroundStyle(Tone.warning)
                }.padding(Spacing.medium).card()
            }
            if model.hasCodex {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text(model.codex).font(.headline)
                    ForEach([model.baseBucket, model.extraBucket], id: \.self) { bucket in
                        VStack(alignment: .leading, spacing: Spacing.regular) {
                            Text(bucket).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(model.quotas.filter { $0.bucket == bucket }) { quota in
                                VStack(alignment: .leading, spacing: Spacing.small) {
                                    HStack {
                                        Text(quota.window).fontWeight(.medium)
                                        if model.selectedQuota?.id == quota.id && model.policy != .all && model.state != .off {
                                            Text(model.selectedLabel).font(.caption2).foregroundStyle(Tone.status("teal"))
                                        }
                                        Spacer()
                                        Text(quota.reset).font(.caption).foregroundStyle(.secondary)
                                        Text("\(quota.used)%").fontWeight(.semibold).monospacedDigit()
                                    }
                                    Text(model.state == .unknownID ? model.noForecast : quota.forecast)
                                        .font(.caption).foregroundStyle(quota.hitInMinutes != nil && model.state != .unknownID ? Tone.warning : Tone.status("gray"))
                                }.padding(Spacing.medium).background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                            }
                        }
                    }
                }
            }
            HStack {
                Button(model.open) {}.buttonStyle(.kitQuiet)
                Spacer()
                Button(model.state == .error || model.state == .stale ? model.retry : model.refresh) {}
                    .buttonStyle(.kitSecondary).disabled(model.state == .busy || model.state == .loading)
            }
            Toggle(model.toggle, isOn: .constant(model.state != .off)).toggleStyle(.switch).font(.caption)
        }.padding(Spacing.large).frame(width: 390).panelBackground()
            .clipShape(RoundedRectangle(cornerRadius: Radius.container))
            .overlay(RoundedRectangle(cornerRadius: Radius.container).strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
    }
}
