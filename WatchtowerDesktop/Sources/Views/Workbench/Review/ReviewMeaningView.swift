import SwiftUI
import WatchtowerCore

/// Deep mode, step 1 (board #328): the AI overview, the agent's
/// walkthrough and the design comments on the round so far, with a way to
/// add one. What the session works on is the identity bar's For list,
/// unfolded in this step (#712 spec §6), not a second copy here.
struct ReviewMeaningView: View {
    let model: ReviewChangesModel
    let compose: (ReviewChangesPaneView.ComposeRequest) -> Void

    private var designComments: [ReviewComment] {
        model.comments.filter { $0.path == nil && $0.status != .resolved }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                ReviewOverviewView(model: model)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                ReviewNotesWalkthrough(model: model)
                HStack {
                    Text("Design comments").font(.headline)
                    Spacer()
                    Button("Add design comment…") {
                        compose(.init(title: "Design comment", lensChoice: true) { body, lens in
                            try await model.addDesignComment(body: body, lens: lens)
                        })
                    }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
                    .disabled(model.round?.status != "open")
                }
                if designComments.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(designComments) { DesignCommentRow(model: model, comment: $0) }
                HStack {
                    Spacer()
                    // A failure lands in lastError.
                    Button("Next: Chapters →") { Task { try? await model.setPhase(.chapters) } }
                        .buttonStyle(.kitSecondary)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity)
        }
    }

    /// One readable column, centred in a wide pane (style guide).
    private static let columnWidth: CGFloat = 760
}

/// A design comment: a draft is edited in place or deleted; others are read-only.
private struct DesignCommentRow: View {
    let model: ReviewChangesModel
    let comment: ReviewComment
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(ReviewLensLabel.name(comment.lens, in: model.lenses)).font(.caption2.weight(.semibold))
                Text(comment.status.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if comment.status == .draft {
                    Button("Delete", role: .destructive) { Task { try? await model.deleteComment(id: comment.id) } }
                        .controlSize(.small)
                }
            }
            if comment.status == .draft {
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(minHeight: 44, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                if text != comment.body {
                    Button("Save") { let body = text; Task { try? await model.editComment(id: comment.id, body: body) } }
                        .controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(comment.body).textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { text = comment.body }
        .onChange(of: comment.body) { _, body in text = body }
    }
}

enum ReviewLensLabel {
    /// A lens id's display name; `intent` and an empty id read as such.
    static func name(_ id: String, in lenses: [ReviewLens]) -> String {
        if id.isEmpty { return "No lens" }
        if id == ReviewChangesModel.intentLens { return "Intent" }
        return lenses.first { $0.id == id }?.name ?? id
    }
}
