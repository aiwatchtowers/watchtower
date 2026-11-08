import SwiftUI
import WatchtowerCore

extension View {
    /// Drag this session row onto another row of the same list to reorder it
    /// (`SessionRowDrag`: `onMove` never starts a drag on these rows, their
    /// click is a tap gesture). `displayed` is the list as rendered; `move`
    /// gets `onMove`-style offsets into it.
    func sessionRowDrag(
        session: TerminalSession,
        listID: Int64?,
        displayed: [TerminalSession],
        move: @escaping (_ source: IndexSet, _ destination: Int) -> Void
    ) -> some View {
        modifier(SessionRowDragModifier(session: session, listID: listID, displayed: displayed, move: move))
    }
}

private struct SessionRowDragModifier: ViewModifier {
    let session: TerminalSession
    let listID: Int64?
    let displayed: [TerminalSession]
    let move: (IndexSet, Int) -> Void

    @State private var isTargeted = false
    @State private var rowSize: CGSize?

    func body(content: Content) -> some View {
        content
            // Observe behind the row: onGeometryChange on the row itself
            // cuts off PanelTab's trailing fill across the panel edge.
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rowSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in rowSize = size }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: PanelTab.cornerRadius)
                        .strokeBorder(.tint, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .draggable(SessionRowDrag.payload(listID: listID, sessionID: session.id)) {
                SessionRowDragPreview(size: rowSize) { content }
            }
            .dropDestination(for: String.self) { payloads, _ in
                isTargeted = false
                guard let payload = payloads.first,
                      let dragged = SessionRowDrag.sessionID(from: payload, listID: listID),
                      let offsets = SessionRowDrag.move(dragged, onto: session.id, in: displayed.map(\.id))
                else { return false }
                move(offsets.source, offsets.destination)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

/// The lifted row keeps its layout, state and badges. A preview is hosted
/// outside the List, so it must supply both the List's width constraint and
/// an opaque surface; otherwise long titles expand and only text is visible.
struct SessionRowDragPreview<Content: View>: View {
    let size: CGSize?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: size?.width, height: size?.height, alignment: .leading)
            .background(Surface.window)
            .clipShape(RoundedRectangle(cornerRadius: PanelTab.cornerRadius))
            .allowsHitTesting(false)
    }
}
