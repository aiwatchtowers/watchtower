import SwiftUI
import WatchtowerCore

/// Deep mode, step 3 (board #328): was the intent met — Done / Partly / Not
/// done per linked target — then every open comment by chapter, read-only,
/// then Send.
struct ReviewWrapUpView: View {
    let model: ReviewChangesModel
    let compose: (ReviewChangesPaneView.ComposeRequest) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Was the intent met?").font(.headline)
                if model.intentItems.isEmpty {
                    Text("No targets are linked to this session").foregroundStyle(.secondary)
                }
                ForEach(model.intentItems) { item in
                    HStack {
                        Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Intent", selection: binding(item)) {
                            Text("Done").tag(Optional(ReviewCheck.State.done))
                            Text("Partly").tag(Optional(ReviewCheck.State.partial))
                            Text("Not done").tag(Optional(ReviewCheck.State.notDone))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.round?.status != "open")
                    }
                }
                Divider()
                Text("Your comments").font(.headline)
                let groups = ReviewWrapUp.commentsByChapter(model.comments, chapters: model.chapters)
                if groups.isEmpty {
                    Text("No comments").foregroundStyle(.secondary)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title).font(.callout.weight(.semibold))
                        ForEach(group.comments) { commentRow($0) }
                    }
                }
                if !model.reverts.isEmpty {
                    Divider()
                    ReviewUndoneList(reverts: model.reverts)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Send review (\(model.draftCount))") { Task { await model.send() } }
                        .disabled(!ReviewChangesHeader.canSend(model))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commentRow(_ comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(place(comment)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !comment.lens.isEmpty {
                    Text(ReviewLensLabel.name(comment.lens, in: model.lenses))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
            Text(comment.body).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func place(_ comment: ReviewComment) -> String {
        guard let path = comment.path else { return "Design" }
        let lines = comment.startLine == comment.endLine ? "\(comment.startLine)" : "\(comment.startLine)–\(comment.endLine)"
        return "\(path):\(lines)"
    }

    private func binding(_ item: ReviewIntentItem) -> Binding<ReviewCheck.State?> {
        Binding(
            get: {
                model.checks.first {
                    $0.chapterKey == ReviewChangesModel.wrapupChapter && $0.lens == ReviewChangesModel.intentLens
                        && $0.itemKey == item.key
                }?.state
            },
            set: { state in
                guard let state else { return }
                if state == .done {
                    try? model.markIntent(item, state: state, note: "") // a failure lands in lastError
                } else {
                    compose(.init(title: state == .partial ? "What is only partly done?" : "What is not done?",
                                  allowsEmpty: true) { note, _ in
                        try model.markIntent(item, state: state, note: note)
                    })
                }
            }
        )
    }
}
