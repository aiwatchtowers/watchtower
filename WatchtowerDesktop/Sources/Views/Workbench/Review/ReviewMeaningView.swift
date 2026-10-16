import SwiftUI
import WatchtowerCore

/// Deep mode, step 1 (board #328): what the session works on — each linked
/// target with its intent and plan task — and the design comments on the
/// round so far, with a way to add one.
struct ReviewMeaningView: View {
    let model: ReviewChangesModel
    let compose: (ReviewChangesPaneView.ComposeRequest) -> Void

    private var designComments: [ReviewComment] {
        model.comments.filter { $0.path == nil && $0.status != .resolved }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What this change is for").font(.headline)
                if model.context.isEmpty {
                    Text("No targets are linked to this session").foregroundStyle(.secondary)
                }
                ForEach(Array(model.context.enumerated()), id: \.offset) { _, item in
                    MeaningCard(item: item)
                }
                Divider()
                HStack {
                    Text("Design comments").font(.headline)
                    Spacer()
                    Button("Add design comment…") {
                        compose(.init(title: "Design comment", lensChoice: true) { body, lens in
                            try model.addDesignComment(body: body, lens: lens)
                        })
                    }
                    .disabled(model.round?.status != "open")
                }
                if designComments.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(designComments) { DesignCommentRow(model: model, comment: $0) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MeaningCard: View {
    let item: ReviewContextItem
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text).font(.callout.weight(.medium))
            if !item.intent.isEmpty {
                Text(item.intent).font(.callout).foregroundStyle(.secondary)
            }
            if let missing = item.missing {
                Label(missing == "plan" ? "plan file not found" : "task not found in the plan",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let plan = item.planText, !plan.isEmpty {
                DisclosureGroup("Plan task", isExpanded: $expanded) {
                    Text(plan)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
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
                    Button("Delete", role: .destructive) { try? model.deleteComment(id: comment.id) }
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
                    Button("Save") { try? model.editComment(id: comment.id, body: text) }
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
