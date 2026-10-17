import SwiftUI
import WatchtowerCore

/// The pure text and decisions behind the Changes pane's Plan 3 views
/// (board #328): Undo reasons, the overview's collapsed line, the agent's
/// walkthrough rows. Views stay thin; the tests pin these.
enum ReviewPresentation {
    static let agentWorkingReason = "Undo is off while the agent is working"
    static let sentReason = "Round already sent"
    static let busyReason = "Undo is off while another action runs"

    /// Why Undo is off, or "" when it is on.
    static func undoReason(roundOpen: Bool, canUndo: Bool, busy: Bool) -> String {
        if canUndo { return "" }
        if !roundOpen { return sentReason }
        return busy ? busyReason : agentWorkingReason
    }

    /// The selected file's hunks as the diff page's Undo zones.
    static func hunks(of file: ReviewDiffFile?, roundOpen: Bool, canUndo: Bool, busy: Bool) -> [MonacoDiffView.Payload.Hunk] {
        let reason = undoReason(roundOpen: roundOpen, canUndo: canUndo, busy: busy)
        return (file?.hunks ?? []).map {
            .init(id: $0.hunkId, newStart: $0.newStart, canUndo: reason.isEmpty, reason: reason)
        }
    }

    /// The selected file's placed notes as the diff page's zones (an unplaced note has no zone).
    static func noteZones(
        _ notes: [ReviewNote], path: String, placements: [Int64: ReviewCommentAnchor.Placement]
    ) -> [MonacoDiffView.Payload.Note] {
        notes.filter { $0.kind == .note && $0.path == path }.compactMap { note in
            placements[note.id].map { .init(startLine: $0.startLine, endLine: $0.endLine, text: note.text) }
        }
    }

    /// The summary's first non-empty line (the collapsed overview).
    static func firstLine(_ summary: String) -> String {
        summary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    static func riskCounts(_ overview: ReviewOverview) -> (high: Int, medium: Int) {
        (overview.risk.filter { $0.level == .high }.count, overview.risk.filter { $0.level == .medium }.count)
    }

    /// `3 high · 1 medium risk`, "" when both are zero.
    static func riskLine(_ overview: ReviewOverview) -> String {
        let counts = riskCounts(overview)
        let parts = [counts.high > 0 ? "\(counts.high) high" : nil, counts.medium > 0 ? "\(counts.medium) medium" : nil]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? "" : joined + " risk"
    }

    /// `<n> changed lines · about <m> min`.
    static func sizeLine(changedLines: Int, minutes: Int) -> String {
        "\(changedLines) changed lines · about \(minutes) min"
    }

    /// The file a coverage `where` entry names (`path` or `path:lines`), if it is in the diff.
    static func coveragePath(_ place: String, files: [ReviewDiffFile]) -> String? {
        if files.contains(where: { $0.path == place }) { return place }
        guard let colon = place.lastIndex(of: ":") else { return nil }
        let path = String(place[..<colon])
        return files.contains { $0.path == path } ? path : nil
    }

    /// One walkthrough row: `file:lines`, the note, and whether it still sits in the file.
    struct WalkRow: Equatable, Identifiable {
        let id: Int64
        let place: String
        let text: String
        let placed: Bool
    }

    /// A note is "no longer in the file" when its file left the diff, or it is
    /// the selected file (the only one whose notes are placed) and found no place.
    static func walkthrough(
        _ notes: [ReviewNote], files: [ReviewDiffFile], selectedPath: String?, placements: [Int64: ReviewCommentAnchor.Placement]
    ) -> [WalkRow] {
        notes.filter { $0.kind == .note }.map { note in
            let inDiff = files.contains { $0.path == note.path }
            let placement = placements[note.id]
            let placed = inDiff && (note.path != selectedPath || placement != nil)
            let start = placement?.startLine ?? note.startLine
            let end = placement?.endLine ?? note.endLine
            let lines = start == end ? "\(start)" : "\(start)–\(end)"
            return WalkRow(id: note.id, place: "\(note.path):\(lines)", text: note.text, placed: placed)
        }
    }

    /// Find Repeats' empty line: before the first search it says nothing is
    /// stored; after one, that nothing repeated. Nil while searching, when
    /// proposals show, or when the error line shows instead.
    static func lessonsEmptyText(searched: Bool, finding: Bool, count: Int, failed: Bool) -> String? {
        guard !finding, count == 0, !failed else { return nil }
        return searched
            ? "No repeated comments found in the last 20 rounds."
            : "No stored proposals. Find Repeats looks for comments you keep repeating."
    }

    static func sourceCaption(_ source: ReviewChapter.Source) -> String? {
        switch source {
        case .agent: "by the agent"
        case .ai: "by AI"
        case .mechanical: nil
        }
    }
}

/// High red, medium orange; low and unknown show nothing.
struct ReviewRiskBadge: View {
    let level: ReviewOverview.Risk.Level?
    var why = ""

    var body: some View {
        switch level {
        case .high: badge("High risk", .red)
        case .medium: badge("Medium risk", .orange)
        case .low, nil: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .background(color.opacity(0.15), in: Capsule())
            .help(why.isEmpty ? text : why)
            .accessibilityLabel(text)
    }
}

/// The reverts the owner made in the round: `path header` per row.
struct ReviewUndoneList: View {
    let reverts: [ReviewRevert]

    var body: some View {
        if !reverts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Undone").font(.caption.weight(.semibold))
                ForEach(Array(reverts.enumerated()), id: \.offset) { _, revert in
                    Text("\(revert.path) \(revert.header)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(revert.at)
                }
            }
        }
    }
}
