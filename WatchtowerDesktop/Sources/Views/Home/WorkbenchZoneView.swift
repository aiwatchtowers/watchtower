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
        HomeZone(title: "Workbench") {
            Button("Open →") { onLink(.workbenches) }
        } content: {
            if failed {
                HomeZoneErrorLine(zone: "Workbench")
            }
            // Space, not dividers, separates the blocks and the suggestion.
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(blocks, id: \.workbenchID) { block in
                    WorkbenchBlockView(block: block, onLink: onLink)
                }
                if let suggestion {
                    HomeSuggestionRow(suggestion: suggestion, onDecide: onDecideSuggestion)
                        .id(suggestion.id)
                }
            }
        }
    }
}

/// One workbench: its name with the session count, its session rows, then
/// its ask rows.
private struct WorkbenchBlockView: View {
    let block: HomeWorkbenchBlock
    let onLink: (HomeLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: Spacing.regular)
                if !block.sessions.isEmpty {
                    Text(Self.sessionCount(block.sessions.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .homeZoneInset()
            .padding(.bottom, Spacing.tight)
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
            HStack(spacing: Spacing.regular) {
                HomeStatusDot(color: tone)
                Text(status.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Spacing.regular)
                Text(SessionStatePresentation.caption(for: status.state))
                    .font(.caption)
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
            .kitRow(isSelected: false)
        }
        .buttonStyle(.plain)
    }

    private func askRow(_ row: WorkbenchAskRow) -> some View {
        Button { onLink(HomeWorkbenchBuilder.link(for: row)) } label: {
            HStack(spacing: Spacing.regular) {
                Chip(text: row.ask.kind.rawValue.capitalized, color: .secondary)
                Text(row.ask.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            // Under its workbench's sessions, past their status dots.
            .padding(.leading, Spacing.large)
            .kitRow(isSelected: false)
        }
        .buttonStyle(.plain)
    }
}

/// The instruction suggestion: what the owner keeps telling agents, with
/// Add (Home's one prominent action) / Dismiss through the CLI.
private struct HomeSuggestionRow: View {
    let suggestion: HomeInstructionSuggestion
    let onDecide: (Int64, Bool) async -> String?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(Self.line(suggestion))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(Tone.error)
            }
            HStack(spacing: Spacing.small) {
                Button("Add") { decide(add: true) }
                    .buttonStyle(.kitPrimary)
                Button("Dismiss") { decide(add: false) }
                    .buttonStyle(.kitQuiet)
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .homeZoneInset()
    }

    /// "You keep telling agents: “…”. Add to your instructions?"; a chat-only
    /// suggestion names the chat and the chat instructions it is added to.
    static func line(_ suggestion: HomeInstructionSuggestion) -> String {
        let quoted = "\u{201C}\(suggestion.text)\u{201D}"
        return suggestion.field == "chat"
            ? "You keep telling the chat: \(quoted). Add to your chat instructions?"
            : "You keep telling agents: \(quoted). Add to your instructions?"
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
