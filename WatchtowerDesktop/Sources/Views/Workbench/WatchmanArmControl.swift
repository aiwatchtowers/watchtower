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
            if status.armed.contains(where: { $0.scope == .session && $0.id == id }) { return .armed }
            return status.isArmed(session: id) ? .viaTarget : .unarmed
        case let .target(id):
            return status.isArmed(target: id) ? .armed : .unarmed
        case .allRunning:
            return status.mode == .off ? .unarmed : .armed
        }
    }

    private var arming: Arming { Self.arming(scope, in: center.lastStatus) }
    private var busy: Bool { center.armingHere.contains(scope) }
    private var since: Date? { center.lastStatus?.modeSince }

    var body: some View {
        Group {
            switch style {
            case .strip: strip
            case .panel: panel
            }
        }
        .task(id: scope) { await center.loadIfNeeded(for: scope) }
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: Spacing.regular) {
            notice.map { NoticeLine(text: $0).frame(maxWidth: ListLayout.textColumn) }
            switch arming {
            case .armed:
                Chip(text: Copy.stripArmed(since: since, calendar: calendar), color: Self.tone, dot: true).fixedSize()
                takeBackButton.help(Copy.takeBackHelp)
            case .viaTarget:
                Chip(text: Copy.stripArmed(since: since, calendar: calendar), color: Self.tone, dot: true)
                    .fixedSize()
                    .help(Copy.viaTargetHelp)
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
            notice.map { NoticeLine(text: $0) }
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

    private var notice: String? { center.armNotices[scope] }

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
