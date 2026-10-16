import SwiftUI
import WatchtowerCore

/// Find Repeats (board #328, spec §13): the house rules mined from the
/// workbench's sent comments. Opening the sheet runs the search; each
/// proposal can be accepted (appended to `.watchtower/review.md`) or dismissed.
struct ReviewLessonsSheet: View {
    let model: ReviewLessonsModel
    let lenses: [ReviewLens]
    @Environment(\.dismiss) private var dismiss
    /// The search finished at least once, so an empty list is an answer.
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find Repeats").font(.headline)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.finding {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for repeated comments…").foregroundStyle(.secondary)
                }
            } else if searched, model.lessons.isEmpty, model.lastError == nil {
                Text("No repeated comments found in the last 20 rounds.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.lessons) { lesson in row(lesson) }
                }
            }
            .frame(maxHeight: 300)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task {
            try? model.load() // a failure shows after the search, through lastError
            await model.findRepeats()
            searched = true
        }
    }

    private func row(_ lesson: ReviewLesson) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(ReviewLensLabel.name(lesson.lens, in: lenses)).font(.caption2.weight(.semibold))
                Text("from \(lesson.sourceCommentIDs.count) comments").font(.caption2).foregroundStyle(.secondary)
            }
            Text(lesson.text).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Dismiss") { Task { await model.dismiss(lesson.id) } }
                Button("Accept") { Task { await model.accept(lesson.id) } }
            }
            .controlSize(.small)
            .disabled(model.finding)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
