import ChatWire
import SwiftUI
import WatchtowerCore

/// The `save_automation` card's body (spec §11): file, trigger, permissions
/// with the widening ones marked "+", outputs, budget, missed runs,
/// concurrency, the assistant's dry-run summary, and the code it confirms —
/// the whole recipe for a new one, the diff against the saved file for an
/// edit.
struct SaveAutomationCardDetails: View {
    let model: SaveAutomationCardModel
    let actionID: Int64
    let differsFromDraft: Bool
    let sessions: SaveAutomationCardModel.DraftSessions

    /// Optional: a card rendered outside the app's window (a design shot)
    /// names the workbench by id.
    @Environment(AppState.self) private var appState: AppState?

    var body: some View {
        Text(model.scopeLine { id in
            appState?.workbenchesViewModel?.summaries.first { $0.project.id == id }?.project.name
        })
        .font(.callout)
        if differsFromDraft {
            Label(SaveAutomationCardModel.draftMismatchWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(.callout)
                .foregroundStyle(line.hasPrefix("+ ") ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let summary = model.dryRunSummary {
            Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        switch sessions {
        case .hidden:
            EmptyView()
        case .unmatched:
            note(SaveAutomationCardModel.unmatchedSessionsLine)
        case .readRecipe:
            note(SaveAutomationCardModel.readRecipeLine)
        case let .shown(run):
            if !run.sessions.isEmpty { AutomationSessionPromptsBlock(sessions: run.sessions) }
            if run.stoppedEarly { note(SaveAutomationCardModel.stoppedEarlyLine) }
        }
        if let text = model.newRecipeText {
            // A new recipe has nothing to diff against: its whole text is
            // what Approve confirms (Review Focus #2).
            RecipeTextDisclosure(title: SaveAutomationCardModel.recipeDisclosureTitle(text), text: text,
                                 modelID: -actionID, contentHash: "save-\(actionID)", slug: "recipe")
                .font(.callout)
        }
        if let diff = model.diff {
            DisclosureGroup(diff.isIdentical ? "No change to the recipe text" : "Show changes") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in row(line) }
                }
            }
            .font(.callout)
            .disabled(diff.isIdentical)
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "questionmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ line: OwnerAskSnapshotDiff.Line) -> some View {
        let (mark, text, tint): (String, String, Color?) = switch line {
        case let .same(text): (" ", text, nil)
        case let .added(text): ("+", text, .green)
        case let .removed(text): ("−", text, .red)
        }
        return HStack(alignment: .top, spacing: Spacing.compact) {
            Text(mark).foregroundStyle(tint ?? .secondary).frame(width: 10)
            Text(text.isEmpty ? " " : text).foregroundStyle(tint == nil ? .secondary : .primary)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { $0.opacity(0.12) } ?? .clear)
        .textSelection(.enabled)
    }
}
