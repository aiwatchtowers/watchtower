import SwiftUI

/// White semibold text on a blue capsule: a session's `#id`, a workbench's
/// new-comments count.
struct WorkbenchCapsuleBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.blue, in: Capsule())
    }
}
