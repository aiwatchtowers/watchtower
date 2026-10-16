import SwiftUI
import WatchtowerCore

/// Find Repeats (board #328, spec §13): the house rules mined from the
/// workbench's sent comments. Opening the sheet shows the stored proposals;
/// the Find Repeats button runs the search (one model call, up to minutes).
/// Each proposal can be accepted (appended to `.watchtower/review.md`) or dismissed.
struct ReviewLessonsSheet: View {
    let model: ReviewLessonsModel
    let lenses: [ReviewLens]
    @Environment(\.dismiss) private var dismiss
    /// The search finished at least once, so an empty list is an answer.
    @State private var searched = false
    /// Reading the stored proposals failed on open.
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find Repeats").font(.headline)
            if let error = model.lastError ?? loadError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.finding {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for repeated comments…").foregroundStyle(.secondary)
                }
            } else if let empty = ReviewPresentation.lessonsEmptyText(
                searched: searched, finding: model.finding, count: model.lessons.count,
                failed: model.lastError != nil || loadError != nil
            ) {
                Text(empty).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.lessons) { lesson in row(lesson) }
                }
            }
            .frame(maxHeight: 300)
            HStack {
                Button("Find Repeats") {
                    Task {
                        loadError = nil
                        await model.findRepeats()
                        searched = true
                    }
                }
                .disabled(model.finding)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task {
            do {
                try model.load()
            } catch {
                loadError = error.localizedDescription
            }
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
                Button("Dismiss") { loadError = nil; Task { await model.dismiss(lesson.id) } }
                Button("Accept") { loadError = nil; Task { await model.accept(lesson.id) } }
            }
            .controlSize(.small)
            .disabled(model.finding)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
