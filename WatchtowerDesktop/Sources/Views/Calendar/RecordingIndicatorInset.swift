import SwiftUI

/// How much bottom space a screen must keep free so the global
/// bottom-trailing recorder pills (`RecordingIndicatorView`) never cover its
/// bottom-most interactive content. Zero while no pill is visible. The root
/// view measures the indicator stack and injects the value; screens opt in
/// with `.clearsRecordingIndicator()`.
enum RecordingIndicatorInset {
    /// The indicator stack's outer padding — the gap between its pills and
    /// the window's bottom edge.
    static let outerPadding: CGFloat = 16
    /// Spacing between pills in the stack.
    static let stackSpacing: CGFloat = 10

    /// `stackHeight` is the measured height of the pill stack without its
    /// outer padding; an empty stack (nothing recording, queued or failed)
    /// measures zero and reserves nothing. While the live-transcript panel is
    /// expanded, the panel itself reserves nothing: it is a transient overlay
    /// the owner opened that may cover content, and the recorder pills sit
    /// above it, so reserving them would pad a gap that clears nothing. Only
    /// what is drawn below the panel (`belowPanelHeight`: the model-download
    /// capsules) still reserves its own height.
    static func reserved(
        stackHeight: CGFloat,
        expandedPanelShown: Bool = false,
        belowPanelHeight: CGFloat = 0
    ) -> CGFloat {
        let covered = expandedPanelShown ? belowPanelHeight : stackHeight
        return covered > 0 ? covered + outerPadding : 0
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

private struct ClearsRecordingIndicator: ViewModifier {
    @Environment(\.recordingIndicatorInset) private var inset

    func body(content: Content) -> some View {
        content.padding(.bottom, inset)
    }
}

extension View {
    /// Pads the view's bottom by the recorder pills' reserved height while
    /// they show. Opt-in, and only on the bottom-most content of a
    /// main-window screen (below any action bar or error label under the
    /// input) — never inside a sheet, onboarding or a setup assistant, where
    /// no pill sits.
    func clearsRecordingIndicator() -> some View {
        modifier(ClearsRecordingIndicator())
    }
}
