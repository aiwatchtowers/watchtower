import SwiftUI

/// One main window's content with the recorder pills over it (#397): the
/// content keeps a band free on the pills' edge, the pills sit in the
/// stored corner, and the two neighbours that share the window's edges —
/// the extract pill (bottom-trailing) and the meeting banner (top) — step
/// aside. Per window, so each window measures itself, and a live resize
/// re-evaluates this view rather than the whole App body.
struct RecordingIndicatorHost<Content: View>: View {
    @ViewBuilder let content: Content
    @AppStorage(RecordingIndicatorCorner.storageKey) private var corner = RecordingIndicatorCorner.default
    @State private var layout = RecordingIndicatorLayout.empty
    /// The window's content size, which a dragged stack is snapped in.
    @State private var size: CGSize = .zero

    var body: some View {
        content
            .padding(corner.insetEdge, layout.reservedInset)
            .overlay(alignment: corner.alignment) {
                RecordingIndicatorView(windowSize: size) { layout = $0 }
            }
            .overlay(alignment: .bottomTrailing) {
                ExtractIndicatorView()
                    .padding(.bottom, corner.extractPillLift(occupiedHeight: layout.occupiedHeight))
            }
            .overlay(alignment: .top) {
                UpcomingMeetingBannerView()
                    .padding(.top, corner.bannerDrop(occupiedHeight: layout.occupiedHeight))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .coordinateSpace(.named(RecordingIndicatorCorner.coordinateSpace))
    }
}
