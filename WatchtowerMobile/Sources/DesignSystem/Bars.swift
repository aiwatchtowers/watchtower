import SwiftUI

/// An opaque bottom bar (mockups' `.primarybar`, design pass spec §2.10): a
/// hairline on top, the content padded 16 × 10, on
/// `Color(.systemBackground)` down to the screen edge. Goes in
/// `.safeAreaInset(edge: .bottom, spacing: 0)`. Opaque on purpose: the
/// translucent `.background(.bar)` let the content under it show through
/// (bugs 4 and 8).
struct BottomActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.cozy)
        }
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .bottom)
    }
}

/// One button of a `PrimaryActionBar`.
struct BarAction {
    let title: String
    var isEnabled = true
    let action: () -> Void
}

/// A screen's one prominent action at the bottom (mockups 9–12): the
/// primary button full width, or a secondary and a primary sharing the
/// width ("Request changes" · "Approve"), in a `BottomActionBar`.
///
///     .safeAreaInset(edge: .bottom, spacing: 0) {
///         PrimaryActionBar(primary: BarAction(title: "Start session") { start() })
///     }
struct PrimaryActionBar: View {
    let primary: BarAction
    var secondary: BarAction?

    /// The buttons' titles in reading order: the secondary first.
    var titles: [String] {
        [secondary?.title, primary.title].compactMap { $0 }
    }

    var body: some View {
        BottomActionBar {
            HStack(spacing: Spacing.regular) {
                if let secondary {
                    Button(secondary.title, action: secondary.action)
                        .buttonStyle(SecondaryActionStyle())
                        .disabled(!secondary.isEnabled)
                }
                Button(primary.title, action: primary.action)
                    .buttonStyle(ProminentActionStyle())
                    .disabled(!primary.isEnabled)
            }
        }
    }
}

/// The one primary action (mockup `.btn.pri` in a bar): full width, 46 pt,
/// the container radius in the button's tint (accent by default) with a
/// white semibold label. Disabled, it keeps its shape on the card fill with
/// a secondary label: on iOS 26 a disabled `.borderedProminent` renders
/// nearly transparent (bugs 5 and 6).
struct ProminentActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(configuration: configuration, isProminent: true)
    }
}

/// The secondary action beside a primary one (mockup `.btn.sec2`): the
/// same shape on the card fill under a hairline, a primary label.
struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(configuration: configuration, isProminent: false)
    }
}

private struct ActionLabel: View {
    let configuration: ButtonStyleConfiguration
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
        let tinted = isProminent && isEnabled
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tinted ? Color.white : isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: PhoneMetrics.barButton)
            .background(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(Fill.card), in: shape)
            .overlay {
                if !tinted {
                    shape.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
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
