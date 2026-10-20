import SwiftUI
import WatchtowerCore

/// Deep mode's three steps in the toolbar (board #328, #712 spec §6):
/// Meaning, Chapters, Wrap-up as a segmented picker and the progress line.
/// Send is the toolbar's own; each step's foot has its Next
/// (`ReviewNextStepButton`).
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
        }
    }
}

/// Deep's way forward at the foot of a step (#712, artboard C): Meaning →
/// Chapters, Chapters → Wrap-up, right-aligned; nothing on Wrap-up, whose
/// Send is the toolbar's.
struct ReviewNextStepButton: View {
    let model: ReviewChangesModel

    private static let next: [ReviewPhase: (phase: ReviewPhase, title: String)] = [
        .meaning: (.chapters, "Next: Chapters →"), .chapters: (.wrapup, "Next: Wrap-up →")
    ]

    var body: some View {
        if let next = Self.next[model.phase] {
            HStack {
                Spacer()
                // A failure lands in lastError.
                Button(next.title) { Task { try? await model.setPhase(next.phase) } }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
    }
}
