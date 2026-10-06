import AppKit
import SwiftUI
import WatchtowerCore

/// The ask drawer's header: kind, title, target, age, "k of N ›", expand
/// and close.
struct OwnerAskDrawerHeader: View {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk

    private var asks: OwnerAsksViewModel { vm.asks }

    var body: some View {
        let stack = asks.stack(projectID: ask.projectID)
        return HStack(spacing: 8) {
            Image(systemName: OwnerAskPresentation.askKindIcon(ask.kind))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(OwnerAskPresentation.askKindLabel(ask.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(ask.title).font(.headline).lineLimit(2)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let position = stack.askPosition(of: ask.id), stack.count > 1 {
                Button {
                    Task { await vm.showNextAsk(after: ask.id, projectID: ask.projectID) }
                } label: {
                    Text("\(OwnerAskPresentation.positionLabel(position, of: stack.count)) ›").monospacedDigit()
                }
                .buttonStyle(.borderless)
                .help("Next ask")
            }
            Button {
                // The terminal under an expanded drawer is hidden: it must
                // not keep the keystrokes.
                // Only the terminal's focus goes; the note field keeps its caret.
                if !asks.drawerExpanded, TerminalHostAttachment.terminalHasFocus(in: NSApp.keyWindow) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                asks.drawerExpanded.toggle()
            } label: {
                Image(systemName: asks.drawerExpanded
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(asks.drawerExpanded ? "Back beside the terminal" : "Expand")
            .accessibilityLabel(asks.drawerExpanded ? "Collapse" : "Expand")
            Button {
                asks.closeDrawer(projectID: ask.projectID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close; your draft is kept")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Kind · #target · age.
    private var caption: String {
        let parts: [String?] = [
            OwnerAskPresentation.askKindLabel(ask.kind),
            ask.targetID.map { "#\($0)" },
            TimeFormatting.shortAge(from: ask.createdAt, now: Date())
        ]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}
