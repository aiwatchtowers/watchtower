import SwiftUI
import WatchtowerCore

/// Deep mode's three steps in the toolbar (board #328, #712 spec §6):
/// Meaning, Chapters, Wrap-up as a segmented picker, the progress line, and
/// Next to the following step. Send is the toolbar's own.
struct ReviewPhaseStrip: View {
    let model: ReviewChangesModel

    private static let titles: [ReviewPhase: String] = [
        .meaning: "1 Meaning", .chapters: "2 Chapters", .wrapup: "3 Wrap-up"
    ]

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            KitSegmentedPicker(
                title: "Phase",
                // A failure lands in lastError.
                selection: Binding(get: { model.phase }, set: { phase in Task { try? await model.setPhase(phase) } }),
                segments: ReviewPhase.allCases.map { KitSegment(value: $0, title: Self.titles[$0] ?? $0.rawValue) }
            )
            Text(ReviewToolbar.progressLine(model))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let next {
                Button("Next →") { Task { try? await model.setPhase(next) } }
                    .buttonStyle(.kitQuiet)
                    .help("Go on to \(Self.titles[next] ?? next.rawValue)")
                    .fixedSize()
            }
        }
    }

    private var next: ReviewPhase? {
        let all = ReviewPhase.allCases
        guard let index = all.firstIndex(of: model.phase), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
