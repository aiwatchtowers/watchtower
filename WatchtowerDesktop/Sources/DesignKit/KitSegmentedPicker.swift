import SwiftUI

/// One choice of a `KitSegmentedPicker`.
public struct KitSegment<Value: Hashable> {
    let value: Value
    let title: String
    var systemImage: String?

    public init(value: Value, title: String, systemImage: String? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
    }
}

/// Pick one of 2–5 values in the Workbench header's capsule: the kit's
/// replacement for `Picker` with `.segmented`. Each segment is a `Toggle`
/// drawn by `SegmentedToggleStyle`; exactly one is on, and turning the
/// selected one off does nothing. Option values must be unique. `title`
/// names the group for VoiceOver; it is not drawn.
public struct KitSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let segments: [KitSegment<Value>]
    @State private var hovered: Value?

    public init(title: String, selection: Binding<Value>, segments: [KitSegment<Value>]) {
        self.title = title
        _selection = selection
        self.segments = segments
    }

    /// The binding behind one segment: on when selected, and only ever turned on.
    public static func isOn(_ value: Value, selection: Binding<Value>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue == value },
            set: { if $0 { selection.wrappedValue = value } }
        )
    }

    public var body: some View {
        HStack(spacing: Spacing.tight) {
            ForEach(segments, id: \.value) { segment in
                Toggle(isOn: Self.isOn(segment.value, selection: $selection)) {
                    if let image = segment.systemImage {
                        Label(segment.title, systemImage: image)
                    } else {
                        Label { Text(segment.title) } icon: { EmptyView() }
                    }
                }
                .toggleStyle(SegmentedToggleStyle(showsIcon: segment.systemImage != nil, isHovered: hovered == segment.value) { inside in
                    if inside { hovered = segment.value } else if hovered == segment.value { hovered = nil }
                })
            }
        }
        .segmentCapsule()
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// The header capsule around a row of segments: a light fill under a
    /// hairline, 26pt tall. Shared by `KitSegmentedPicker` and the Workbench
    /// header's view buttons.
    public func segmentCapsule() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return padding(Spacing.tight)
            .frame(height: 26)
            .background(SegmentCapsule.fill, in: shape)
            .overlay { shape.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline) }
    }
}

/// Off the fill scale on purpose: the capsule sits between `Fill.rest` and `Fill.card`.
private enum SegmentCapsule {
    static var fill: Color { Color.primary.opacity(0.05) }
}
