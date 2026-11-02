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

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: PanelTab.cornerRadius)
                        .strokeBorder(.tint, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .draggable(SessionRowDrag.payload(listID: listID, sessionID: session.id)) {
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
                    .padding(Spacing.compact)
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
