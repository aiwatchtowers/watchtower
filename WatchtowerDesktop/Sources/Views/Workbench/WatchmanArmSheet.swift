import SwiftUI
import WatchtowerCore

/// The arm sheet (spec 2026-11-16 §2, §5, D21): what a first hand-over turns
/// on and what learning costs, what stays the owner's, what is not caught,
/// and the warnings to arm knowing (an unprotected main, a repository the
/// git guard cannot go into). A short blocking flow, so a sheet.
struct WatchmanArmSheet: View {
    let content: WatchmanArmSheetContent
    /// The confirm checks again: Hand to Watchman waits.
    var busy = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// At most six rows show; more scroll.
    static let visibleRows = 6

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(min(rows, visibleRows)) * ListLayout.lineMinHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(content.title).font(.title3.weight(.semibold))
                if let notice = content.notice {
                    line(icon: "arrow.triangle.2.circlepath", tone: Tone.warning, text: notice)
                }
                Text(content.body).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !content.sessions.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(WatchmanArmingCopy.sessionsHeader(content.sessions.count)).font(.callout.weight(.semibold))
                    // A long list scrolls (about six rows); the buttons stay on screen.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(content.sessions, id: \.self) { session in
                                Text(session).font(.callout).lineLimit(1).frame(minHeight: ListLayout.lineMinHeight)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: Self.listHeight(rows: content.sessions.count))
                }
            }
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(content.lines, id: \.self) { line(icon: $0.icon, tone: .secondary, text: $0.text) }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            ForEach(content.warnings, id: \.self) { warning in
                line(icon: "exclamationmark.triangle.fill", tone: Tone.warning, text: warning)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(content.cancel, action: onCancel)
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(content.confirm, action: onConfirm)
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(width: PaneWidth.narrowPage + Spacing.hero, alignment: .topLeading)
    }

    private func line(icon: String, tone: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone).frame(width: IconSize.composer)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Presents the arm sheet over the main window, whichever screen is on it:
/// a strip, a target panel or the tray asked for it (`WatchmanCenter.sheet`).
struct WatchmanArmSheetHost: ViewModifier {
    let center: WatchmanCenter?

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { center?.sheet }, set: { if $0 == nil { center?.sheet = nil } })) { request in
            WatchmanArmSheet(
                content: request.content,
                busy: center?.confirming ?? false,
                onCancel: { center?.sheet = nil },
                onConfirm: { [token = request.token] in Task { await center?.confirmSheet(token: token) } }
            )
        }
    }
}
