import SwiftUI
import WatchtowerCore

/// Home's Workbench zone: per workbench, the live sessions to look at (state
/// dot and caption from `SessionStatePresentation`) and the open asks, then
/// the instruction suggestion as the last row. A failed read says so.
struct WorkbenchZoneView: View {
    let blocks: [HomeWorkbenchBlock]
    let suggestion: HomeInstructionSuggestion?
    let failed: Bool
    let onLink: (HomeLink) -> Void
    /// Add (true) / Dismiss (false) the suggestion; the error to show, nil on success.
    let onDecideSuggestion: (Int64, Bool) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HomeZoneTitle(title: "WORKBENCH") {
                Button("Open →") { onLink(.workbenches) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            if failed {
                HomeZoneErrorLine(zone: "Workbench")
            }
            ForEach(Array(blocks.enumerated()), id: \.element.workbenchID) { index, block in
                if index > 0 { Divider().padding(.vertical, 4) }
                WorkbenchBlockView(block: block, onLink: onLink)
            }
            if let suggestion {
                if !blocks.isEmpty || failed { Divider().padding(.vertical, 4) }
                HomeSuggestionRow(suggestion: suggestion, onLink: onLink, onDecide: onDecideSuggestion)
                    .id(suggestion.id)
            }
        }
        .homeZoneCard()
    }
}

/// One workbench: its name with the session count, its session rows, then
/// its ask rows.
private struct WorkbenchBlockView: View {
    let block: HomeWorkbenchBlock
    let onLink: (HomeLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !block.sessions.isEmpty {
                    Text(Self.sessionCount(block.sessions.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 2)
            ForEach(block.sessions, id: \.sessionID) { status in
                sessionRow(status)
            }
            ForEach(block.asks, id: \.ask.id) { row in
                askRow(row)
            }
        }
    }

    /// "1 session", "2 sessions".
    static func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    @ViewBuilder private func sessionRow(_ status: SessionAgentStatus) -> some View {
        let tone = SessionStatePresentation.color(for: status.state).color
        Button {
            if let link = HomeWorkbenchBuilder.link(for: status) { onLink(link) }
        } label: {
            HStack(spacing: 8) {
                HomeStatusDot(color: tone)
                Text(status.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(SessionStatePresentation.caption(for: status.state))
                    .font(.caption)
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func askRow(_ row: WorkbenchAskRow) -> some View {
        Button { onLink(HomeWorkbenchBuilder.link(for: row)) } label: {
            HStack(spacing: 8) {
                Text(row.ask.kind.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
                Text(row.ask.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.vertical, 2)
    }
}

/// The instruction suggestion: what the owner keeps telling agents, with
/// Add / Dismiss (through the CLI) and More… (Settings → System).
private struct HomeSuggestionRow: View {
    let suggestion: HomeInstructionSuggestion
    let onLink: (HomeLink) -> Void
    let onDecide: (Int64, Bool) async -> String?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.line(suggestion))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Add") { decide(add: true) }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { decide(add: false) }
                Button("More\u{2026}") { onLink(.instructionSettings) }
                    .buttonStyle(.link)
            }
            .controlSize(.small)
            .disabled(busy)
        }
    }

    /// "You keep telling agents: “…”. Add to your instructions?"
    static func line(_ suggestion: HomeInstructionSuggestion) -> String {
        "You keep telling agents: \u{201C}\(suggestion.text)\u{201D}. Add to your instructions?"
    }

    private func decide(add: Bool) {
        busy = true
        Task {
            let failure = await onDecide(suggestion.id, add)
            errorText = failure
            // A decision stays disabled until the re-read replaces or removes the row.
            busy = failure == nil
        }
    }
}
