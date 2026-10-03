import SwiftUI
import WatchtowerCore

/// The ✦ button next to a settled selection (spec §9.2), like macOS
/// Writing Tools: a 24 pt rounded square with a warm orange gradient.
struct AskAIButton: View {
    static let side: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.side, height: Self.side)
                .background(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.28), Color(red: 0.95, green: 0.4, blue: 0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help("Ask AI about the selection (⌘I)")
        .accessibilityLabel("Ask AI about the selection")
    }
}

/// The ✦ over the editor, at the right of the selection's box while
/// `CodeQuestionCenter` shows it; kept inside the editor and off its
/// scroll bar. Clicking it asks the page, as ⌘I does.
struct AskAIButtonOverlay: View {
    let questions: CodeQuestionCenter
    let project: Workbench

    var body: some View {
        GeometryReader { geometry in
            if let rect = questions.buttonRects[project.id] {
                AskAIButton {
                    let questions = questions
                    let project = project
                    Task { await questions.askAIFromMenu(project: project) }
                }
                .position(Self.buttonCenter(for: rect, in: geometry.size))
            }
        }
    }

    /// The button's centre for a selection box in the page's points.
    static func buttonCenter(for rect: CGRect, in size: CGSize) -> CGPoint {
        let half = AskAIButton.side / 2
        let scrollBar: CGFloat = 14
        let x = min(max(rect.maxX + 6 + half, half), max(half, size.width - half - scrollBar))
        let y = min(max(rect.minY + half - 4, half), max(half, size.height - half))
        return CGPoint(x: x, y: y)
    }
}
