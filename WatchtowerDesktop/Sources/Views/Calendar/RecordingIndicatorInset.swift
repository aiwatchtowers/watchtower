import SwiftUI

/// How much bottom space a composer must keep free so the global
/// bottom-trailing recorder pills (`RecordingIndicatorView`) never cover it.
/// Zero while no pill is visible. The root view measures the indicator stack
/// and injects the value; `ChatInput` (every bottom composer: main chat, the
/// Discuss chats, onboarding) pads itself by it.
enum RecordingIndicatorInset {
    /// The indicator stack's outer padding — the gap between its pills and
    /// the window's bottom edge.
    static let outerPadding: CGFloat = 16

    /// `stackHeight` is the measured height of the pill stack without its
    /// outer padding; an empty stack (nothing recording, queued or failed)
    /// measures zero and reserves nothing.
    static func reserved(stackHeight: CGFloat) -> CGFloat {
        stackHeight > 0 ? stackHeight + outerPadding : 0
    }
}

private struct RecordingIndicatorInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var recordingIndicatorInset: CGFloat {
        get { self[RecordingIndicatorInsetKey.self] }
        set { self[RecordingIndicatorInsetKey.self] = newValue }
    }
}
