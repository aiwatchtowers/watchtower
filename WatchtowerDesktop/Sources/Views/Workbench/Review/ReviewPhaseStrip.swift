import SwiftUI
import WatchtowerCore

/// Deep mode's three steps under the header (board #328): Meaning, Chapters,
/// Wrap-up. Each step is clickable; Next moves on, and Wrap-up shows Send.
struct ReviewPhaseStrip: View {
    let model: ReviewChangesModel

    private static let titles: [ReviewPhase: String] = [
        .meaning: "1 Meaning", .chapters: "2 Chapters", .wrapup: "3 Wrap-up"
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ReviewPhase.allCases, id: \.self) { phase in
                Button(Self.titles[phase] ?? phase.rawValue) { Task { try? await model.setPhase(phase) } } // a failure lands in lastError
                    .buttonStyle(.plain)
                    .fontWeight(phase == model.phase ? .semibold : .regular)
                    .foregroundStyle(phase == model.phase ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(phase == model.phase ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    .accessibilityAddTraits(phase == model.phase ? .isSelected : [])
                if phase != ReviewPhase.allCases.last { Text("·").foregroundStyle(.secondary) }
            }
            Spacer()
            if let next {
                Button("Next") { Task { try? await model.setPhase(next) } }
            } else {
                Button("Send") { Task { await model.send() } }
                    .disabled(!ReviewChangesHeader.canSend(model))
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
    }

    private var next: ReviewPhase? {
        let all = ReviewPhase.allCases
        guard let index = all.firstIndex(of: model.phase), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
