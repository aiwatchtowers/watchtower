import SwiftUI

/// One choice of a `KitSegmentedPicker`.
struct KitSegment<Value: Hashable> {
    let value: Value
    let title: String
    var systemImage: String?
}

/// Pick one of 2–5 values in the Workbench header's capsule: the kit's
/// replacement for `Picker` with `.segmented`. Each segment is a `Toggle`
/// drawn by `SegmentedToggleStyle`; exactly one is on, and turning the
/// selected one off does nothing.
struct KitSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [KitSegment<Value>]
    @State private var hovered: Value?

    private static var containerFill: Color { Color.primary.opacity(0.05) }

    /// The binding behind one segment: on when selected, and only ever turned on.
    static func isOn(_ value: Value, selection: Binding<Value>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue == value },
            set: { if $0 { selection.wrappedValue = value } }
        )
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                Toggle(isOn: Self.isOn(segment.value, selection: $selection)) {
                    if let image = segment.systemImage {
                        Label(segment.title, systemImage: image)
                    } else {
                        Label { Text(segment.title) } icon: { EmptyView() }
                    }
                }
                .toggleStyle(SegmentedToggleStyle(isHovered: hovered == segment.value) { inside in
                    if inside { hovered = segment.value } else if hovered == segment.value { hovered = nil }
                })
            }
        }
        .padding(2)
        .frame(height: 26)
        .background(Self.containerFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}
