import SwiftUI

/// An opaque bottom bar (design pass spec §2.10): a hairline on top, the
/// content padded 16 × 10, on `Color(.systemBackground)` down to the screen
/// edge. Goes in `.safeAreaInset(edge: .bottom, spacing: 0)`. It replaces the
/// translucent `.background(.bar)` bars, which let the content under them
/// show through (bugs 4 and 8).
struct BottomActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, 10)
        }
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .bottom)
    }
}

/// The one primary action of a bar: full width, 50 pt, a capsule in the
/// button's tint (accent by default) with a white semibold label. Disabled,
/// it keeps its shape as a grey capsule with a secondary label: on iOS 26 a
/// disabled `.borderedProminent` renders nearly transparent (bugs 5 and 6).
/// The secondary button of a pair stays `.bordered` with `.controlSize(.large)`.
struct ProminentActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentActionLabel(configuration: configuration)
    }
}

private struct ProminentActionLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// The red Record button: the symbol forced monochrome white, so it draws
/// no accent ring inside the red capsule (shots 01 and 03). `fillsWidth`
/// for a bar's pair, where it takes its half.
/// Always "Record" at the 44 pt large size (Now, the agenda, event detail).
struct RecordButton: View {
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Record", systemImage: "record.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(PhoneTone.red.color)
        .controlSize(.large)
    }
}
