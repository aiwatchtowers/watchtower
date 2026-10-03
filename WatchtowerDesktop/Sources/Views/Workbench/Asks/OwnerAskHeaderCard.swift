import SwiftUI
import WatchtowerCore

/// The agent's short header of an ask (spec 2026-10-03 Part 8): what it is,
/// where to look (`focus`), and on a later review round what changed since
/// the last one. `showDiff`, when given, adds "Show diff"; `showFocus` makes
/// a review's focus items jump to their place in the document.
struct OwnerAskHeaderCard: View {
    let ask: OwnerAsk
    var showDiff: (() -> Void)?
    var showFocus: ((OwnerAskFocus) -> Void)?

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 8) {
                if !ask.summary.isEmpty {
                    Text(ask.summary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !ask.payload.focus.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Look at").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(ask.payload.focus.enumerated()), id: \.offset) { _, item in
                            focusRow(item)
                        }
                    }
                }
                if !ask.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(changesTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if let showDiff {
                                Button("Show diff", action: showDiff).controlSize(.small)
                            }
                        }
                        Text(ask.changes)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var hasContent: Bool {
        !ask.summary.isEmpty || !ask.payload.focus.isEmpty || !ask.changes.isEmpty
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
                Text(item.text).fixedSize(horizontal: false, vertical: true)
                if !place.isEmpty {
                    if let showFocus {
                        Button(place) { showFocus(item) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .lineLimit(1)
                    } else {
                        Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}
