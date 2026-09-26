import SwiftUI

/// Pure state derivation for the `.dictationHighlight` field modifier,
/// testable without rendering (the `DictationSpan` precedent).
enum DictationHighlightState: Equatable {
    case none, recording, paused

    static func derive(activeTargetID: String?, phase: DictationPhase, targetID: String) -> Self {
        guard activeTargetID == targetID else { return .none }
        switch phase {
        case .recording:
            return .recording
        case .paused:
            return .paused
        case .idle, .stopping, .cleaning, .failed:
            return .none
        }
    }
}

extension View {
    /// Accent border + subtle tint on the field a dictation is writing into.
    /// `center: nil` (no environment) renders unmodified.
    func dictationHighlight(
        targetID: String,
        center: DictationCenter?,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(DictationHighlightModifier(
            targetID: targetID,
            center: center,
            cornerRadius: cornerRadius
        ))
    }
}

/// Background tint + border are always in the tree with clear/zero styling in
/// `.none` — a structural if/else would give the decorated field a new view
/// identity every time a dictation starts or stops, resetting focus and any
/// `NSViewRepresentable` state (`ExpandingTextInput`).
private struct DictationHighlightModifier: ViewModifier {
    let targetID: String
    let center: DictationCenter?
    let cornerRadius: CGFloat

    @State private var pulse = false

    func body(content: Content) -> some View {
        // Reads on the @Observable center during body are auto-tracked, so
        // phase/target changes re-render without timers or onReceive.
        let state = derived
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(state == .none ? 0 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor(for: state), lineWidth: state == .none ? 0 : 2)
                    // The pulse animates only while `.recording`; `.paused`
                    // holds a static border at the dim opacity.
                    .animation(
                        state == .recording
                            ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                            : nil,
                        value: pulse
                    )
            )
            // `initial: true` covers a field first rendered mid-dictation.
            .onChange(of: state == .recording, initial: true) { _, isRecording in
                pulse = isRecording
            }
    }

    private var derived: DictationHighlightState {
        guard let center else { return .none }
        return DictationHighlightState.derive(
            activeTargetID: center.activeTargetID,
            phase: center.phase,
            targetID: targetID
        )
    }

    private func borderColor(for state: DictationHighlightState) -> Color {
        switch state {
        case .none:
            return .clear
        case .recording:
            return Color.accentColor.opacity(pulse ? 0.9 : 0.45)
        case .paused:
            return Color.accentColor.opacity(0.45)
        }
    }
}
