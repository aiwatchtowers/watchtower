import SwiftUI
import WatchtowerCore

/// Hand to Watchman / Take back for one session (the session strip) or one
/// target (the target panel), over `WatchmanCenter` (spec 2026-11-16 §2,
/// D47). The arm sheet a first arm opens is the workbench page's
/// (`WatchmanArmSheet`); a failed call stays under the control.
struct WatchmanArmControl: View {
    enum Style {
        /// One row in the session strip.
        case strip
        /// The target panel's block with its caption.
        case panel
    }

    let center: WatchmanCenter
    let scope: WatchmanArmScope
    /// The workbench the sheet's title names.
    let workbench: String
    let style: Style
    /// "Sleep since" on this clock (a design shot pins one).
    @Environment(\.calendar) private var calendar

    private typealias Copy = WatchmanArmingCopy
    /// The tint of Watchman's own marks (the armed chip and card).
    static let tone = Tone.status("purple")

    /// How the scope stands in the last status read.
    enum Arming: Equatable {
        case unarmed
        /// Handed over itself: Take back is here.
        case armed
        /// A session under an armed target: taken back on the target.
        case viaTarget
    }

    static func arming(_ scope: WatchmanArmScope, in status: WatchmanStatus?) -> Arming {
        guard let status else { return .unarmed }
        switch scope {
        case let .session(id):
            // Under an armed target it stays the twin's whatever its own row
            // says: Take back here would not return it.
            if let entry = status.armedSessions[id], entry.target != 0 { return .viaTarget }
            return status.isArmed(session: id) ? .armed : .unarmed
        case let .target(id):
            return status.isArmed(target: id) ? .armed : .unarmed
        case .allRunning:
            return status.mode == .off ? .unarmed : .armed
        }
    }

    /// "Sleep since": the session's own arming time (its target's when it
    /// came with one) or the target row's; else the status's `mode_since`.
    static func since(_ scope: WatchmanArmScope, in status: WatchmanStatus?) -> Date? {
        guard let status else { return nil }
        let own: Date? = switch scope {
        case let .session(id): status.armedSessions[id]?.armedAt
        case let .target(id): status.armed.first { $0.scope == .target && $0.id == id }?.armedAt
        case .allRunning: nil
        }
        return own ?? status.modeSince
    }

    private var arming: Arming { Self.arming(scope, in: center.lastStatus) }
    private var busy: Bool { center.armingHere.contains(scope) }
    private var viaTargetHelp: String { Self.viaTargetHelp(scope, in: center.lastStatus) }

    /// The via-target tooltip: the covering target, and whether the session
    /// also has its own row.
    static func viaTargetHelp(_ scope: WatchmanArmScope, in status: WatchmanStatus?) -> String {
        guard case let .session(id) = scope, let status, let entry = status.armedSessions[id] else { return "" }
        let direct = status.armed.contains { $0.scope == .session && $0.id == id }
        return Copy.viaTargetHelp(target: entry.target, direct: direct)
    }
    private var since: Date? { Self.since(scope, in: center.lastStatus) }
    /// The warning lines under a control: the daemon is stopped while it is
    /// handed over (nothing decides), then the last call's notice.
    static func noticeLines(arming: Arming, daemon: WatchmanDaemonState, notice: String?) -> [String] {
        var lines: [String] = []
        if arming != .unarmed, daemon == .stopped { lines.append(Copy.daemonStopped) }
        if let notice { lines.append(notice) }
        return lines
    }

    private var lines: [String] {
        Self.noticeLines(arming: arming, daemon: center.daemon, notice: center.armNotices[scope])
    }

    var body: some View {
        Group {
            switch style {
            case .strip: strip
            case .panel: panel
            }
        }
        // Each appearance rereads the arming (an arm made elsewhere shows).
        .task(id: scope) { await center.reread() }
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: Spacing.regular) {
            // A notice wins room over the session name, which truncates.
            if hasNotices { notices.frame(maxWidth: ListLayout.textColumn).layoutPriority(1) }
            switch arming {
            case .armed:
                Chip(text: Copy.stripArmed(since: since, calendar: calendar), color: Self.tone, dot: true).fixedSize()
                takeBackButton.help(Copy.takeBackHelp)
            case .viaTarget:
                Chip(text: Copy.stripArmed(since: since, calendar: calendar), color: Self.tone, dot: true)
                    .fixedSize()
                    .help(viaTargetHelp)
            case .unarmed:
                handButton.help(Copy.handHelp)
            }
        }
    }

    // MARK: - Panel

    @ViewBuilder private var panel: some View {
        let target = Self.targetID(scope)
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if arming == .unarmed {
                handButton
                Text(Copy.targetUnarmedCaption(target: target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                armedCard(target)
            }
            notices
        }
    }

    private func armedCard(_ target: Int64) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "moon.stars").foregroundStyle(Self.tone)
                Text(Copy.targetArmed(since: since, calendar: calendar))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                takeBackButton
            }
            Text(Copy.targetArmedCaption(target: target))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.tone.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }

    // MARK: - Parts

    private var handButton: some View {
        Button {
            Task { await center.handTo(scope, workbench: workbench) }
        } label: {
            Label(Copy.handTo, systemImage: "moon.stars")
        }
        .buttonStyle(.kitSecondary)
        .fixedSize()
        .disabled(busy)
    }

    private var takeBackButton: some View {
        Button(Copy.takeBack) {
            Task { await center.disarm(scope) }
        }
        .buttonStyle(.kitSecondary)
        .fixedSize()
        .disabled(busy)
    }

    /// The lines under the control: the daemon is stopped, the arming could
    /// not be read (with Retry), the last call's notice.
    private var hasNotices: Bool {
        !lines.isEmpty || center.armingReadError != nil
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let error = center.armingReadError {
                HStack(spacing: Spacing.small) {
                    NoticeLine(text: Copy.statusReadFailed(error))
                    Button(Copy.retry) { Task { await center.reread() } }
                        .buttonStyle(.kitQuiet)
                        .fixedSize()
                }
            }
            ForEach(lines, id: \.self) { NoticeLine(text: $0) }
        }
    }

    private static func targetID(_ scope: WatchmanArmScope) -> Int64 {
        if case let .target(id) = scope { return id }
        return 0
    }
}

/// A failed call's line under (or beside) its control: a warning mark and
/// the text, the whole of it in the tooltip.
private struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).lineLimit(2).truncationMode(.tail)
        }
        .font(.caption)
        .help(text)
    }
}
