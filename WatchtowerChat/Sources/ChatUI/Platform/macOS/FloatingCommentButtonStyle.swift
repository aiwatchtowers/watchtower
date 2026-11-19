#if os(macOS)
import AppKit
import SwiftUI
import WatchtowerDesign

/// The floating Comment button (#165): an opaque, shadowed chip — the default translucent bezel let the document's
/// text show through it. The chat feed's "Ask about this" chip and the app's commentable documents share it.
public struct FloatingCommentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Color(nsColor: configuration.isPressed ? .controlColor : .windowBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}
#endif
