import SwiftUI

/// One button a row reveals when swiped (mockup §2's `.sa`): its title on its tone's fill.
struct SwipeAction: Identifiable {
    let title: String
    let tone: PhoneTone
    let action: () -> Void

    var id: String { title }
}

/// A flat row that swipes outside a `List` (mobile Inbox mockup §2): left reveals `trailing` (Done, Snooze), right
/// reveals `leading` (Hide); a tap on a revealed button runs it and closes the row, a tap elsewhere closes it. Every
/// action is also offered to accessibility, and the host's context menu holds the full verb set, so the swipe is
/// never the only way. `revealed` opens it on one side from the start (the screenshot tour).
struct SwipeRow<Content: View>: View {
    static var buttonWidth: CGFloat { 76 }

    let leading: [SwipeAction]
    let trailing: [SwipeAction]
    @ViewBuilder var content: Content
    @State private var offset: CGFloat
    @State private var dragStart: CGFloat?

    init(
        leading: [SwipeAction] = [],
        trailing: [SwipeAction] = [],
        revealed: HorizontalEdge? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.leading = leading
        self.trailing = trailing
        self.content = content()
        let start: CGFloat = switch revealed {
        case .leading?: CGFloat(leading.count) * Self.buttonWidth
        case .trailing?: -CGFloat(trailing.count) * Self.buttonWidth
        case nil: 0
        }
        _offset = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                buttons(leading)
                Spacer(minLength: 0)
                buttons(trailing)
            }
            .opacity(offset == 0 ? 0 : 1)
            content
                .background(PhoneSurface.page)
                .offset(x: offset)
                .simultaneousGesture(drag)
                .onTapGesture { if offset != 0 { close() } }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(leading + trailing) { item in
                Button(item.title, action: item.action)
            }
        }
    }

    private func buttons(_ actions: [SwipeAction]) -> some View {
        HStack(spacing: 0) {
            ForEach(actions) { item in
                Button {
                    close()
                    item.action()
                } label: {
                    Text(item.title)
                        .font(TypeScale.kind)
                        .foregroundStyle(Color.white)
                        .frame(width: Self.buttonWidth)
                        .frame(maxHeight: .infinity)
                        .background(item.tone.color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start = dragStart ?? offset
                dragStart = start
                offset = clamp(start + value.translation.width)
            }
            .onEnded { _ in
                dragStart = nil
                withAnimation(.snappy) { offset = settle(offset) }
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, -CGFloat(trailing.count) * Self.buttonWidth), CGFloat(leading.count) * Self.buttonWidth)
    }

    /// Past half a button the row stays open on that side, else it closes.
    private func settle(_ value: CGFloat) -> CGFloat {
        if value > Self.buttonWidth / 2 { return CGFloat(leading.count) * Self.buttonWidth }
        if value < -Self.buttonWidth / 2 { return -CGFloat(trailing.count) * Self.buttonWidth }
        return 0
    }

    private func close() {
        withAnimation(.snappy) { offset = 0 }
    }
}
