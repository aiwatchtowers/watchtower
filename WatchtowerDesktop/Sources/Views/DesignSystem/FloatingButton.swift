import SwiftUI

/// The label of a floating capsule button (Chat's "Jump to latest"): white
/// caption text on an accent capsule with a soft shadow. The caller wraps it
/// in a plain-style `Button`; the styling stays on the label so the whole
/// painted capsule is clickable.
struct FloatingButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
    }
}
