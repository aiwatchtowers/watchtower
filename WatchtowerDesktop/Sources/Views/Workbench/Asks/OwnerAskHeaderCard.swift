import SwiftUI
import WatchtowerCore

/// The agent's short header of an ask (spec 2026-10-03 Part 8): what it is,
/// where to look (`focus`), and on a later review round what changed since
/// the last one. `showDiff`, when given, adds "Show diff"; `focusAction`
/// gives a focus item a link to its place in the document — nil for one
/// whose place is not in the snapshot, listed without a link. The agent's
/// text renders as markdown (#394); its links route by `OwnerAskLinks`.
struct OwnerAskHeaderCard: View {
    let ask: OwnerAsk
    var showDiff: (() -> Void)?
    var focusAction: (OwnerAskFocus) -> (() -> Void)? = { _ in nil }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 8) {
                if !ask.summary.isEmpty {
                    MarkdownView(text: ask.summary)
                }
                if !ask.payload.focus.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Look at").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(ask.payload.focus.enumerated()), id: \.offset) { _, item in
                            focusRow(item)
                        }
                    }
                }
                if !ask.changes.isEmpty || showDiff != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(changesTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if let showDiff {
                                Button("Show diff", action: showDiff).controlSize(.small)
                            }
                        }
                        if !ask.changes.isEmpty {
                            MarkdownView(text: ask.changes)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var hasContent: Bool {
        !ask.summary.isEmpty || !ask.payload.focus.isEmpty || !ask.changes.isEmpty || showDiff != nil
    }

    private var changesTitle: String {
        ask.previousAskID.map { "Changes since #\($0)" } ?? "Changes"
    }

    @ViewBuilder
    private func focusRow(_ item: OwnerAskFocus) -> some View {
        let place = item.heading.isEmpty ? item.quote : item.heading
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                MarkdownView(text: item.text)
                if !place.isEmpty {
                    if let action = focusAction(item) {
                        Button(action: action) { Text(MarkdownView.inlineLabel(place)) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .lineLimit(1)
                    } else {
                        Text(MarkdownView.inlineLabel(place)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}
