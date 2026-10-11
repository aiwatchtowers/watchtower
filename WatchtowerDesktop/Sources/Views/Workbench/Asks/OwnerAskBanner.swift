import SwiftUI
import WatchtowerCore

/// Over the terminal of a session with open asks (spec 2026-10-03 Part 8):
/// the oldest one's number (board #500) and title and how many more wait.
/// A Full ask has Open, which shows it in the drawer beside this terminal;
/// a Quick ask (spec 2026-10-10 Part 9.1) is answered right here with its
/// one-tap row (`OwnerAskQuickActions`), Details opening the drawer — one
/// raised from the terminal's question says "From chat · N min".
struct OwnerAskBanner: View {
    /// The session's open asks, oldest first; never empty.
    let asks: [OwnerAsk]
    let vm: WorkbenchesViewModel

    var body: some View {
        if let first = asks.first {
            Group {
                if let row = OwnerAskQuickRow(ask: first) {
                    VStack(alignment: .leading, spacing: 6) {
                        titleLine(first)
                        OwnerAskQuickActions(vm: vm, ask: first, row: row) { open(first) }
                            // A new ask starts with its options, not the last one's Reply.
                            .id(first.id)
                    }
                } else {
                    HStack(spacing: 8) {
                        titleLine(first)
                        Button("Open") { open(first) }
                            .controlSize(.small)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private func titleLine(_ first: OwnerAsk) -> some View {
        HStack(spacing: 8) {
            Image(systemName: OwnerAskPresentation.askKindIcon(first.kind))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(OwnerAskPresentation.askKindLabel(first.kind))
            Text("Agent asks: \(Text.askNumber(first.id)) \(first.title)")
                .lineLimit(1)
                .truncationMode(.tail)
            if asks.count > 1 {
                Text("+\(asks.count - 1) more").foregroundStyle(.secondary)
            }
            if first.origin == .chat {
                OwnerAskChatMark(askedAt: first.chatAskedAt)
            }
            Spacer(minLength: 8)
        }
    }

    private func open(_ ask: OwnerAsk) {
        vm.asks.openDrawer(ask)
    }
}

/// "From chat · N min" on an ask raised from the agent's terminal question,
/// its age refreshed each minute; nothing for a stamp it cannot read.
struct OwnerAskChatMark: View {
    let askedAt: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let mark = OwnerAskPresentation.chatMark(askedAt: askedAt, now: context.date) {
                Text(mark)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Asked in the terminal and not answered there")
            }
        }
    }
}
