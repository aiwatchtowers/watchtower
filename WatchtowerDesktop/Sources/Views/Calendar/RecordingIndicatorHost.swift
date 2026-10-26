import SwiftUI

/// One main window's content with the recorder pills floating over it
/// (#397): the pills sit where the owner left them, the content keeps its
/// full size, and the two neighbours that share the window's edges — the
/// extract pill (bottom-trailing) and the meeting banner (top) — step aside
/// while the pills are docked in their corner. Per window, so each window
/// measures itself, and a live resize re-evaluates this view rather than
/// the whole App body.
struct RecordingIndicatorHost<Content: View>: View {
    @ViewBuilder let content: Content
    @AppStorage(RecordingIndicatorCorner.storageKey) private var corner = RecordingIndicatorCorner.default
    @State private var occupiedHeight: CGFloat = 0
    /// The window's content size, which the stack is kept inside.
    @State private var size: CGSize = .zero

    var body: some View {
        content
            .overlay(alignment: corner.alignment) {
                RecordingIndicatorView(windowSize: size) { occupiedHeight = $0 }
            }
            .overlay(alignment: .bottomTrailing) {
                ExtractIndicatorView()
                    .padding(.bottom, corner.extractPillLift(occupiedHeight: occupiedHeight))
            }
            .overlay(alignment: .top) {
                UpcomingMeetingBannerView()
                    .padding(.top, corner.bannerDrop(occupiedHeight: occupiedHeight))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .coordinateSpace(.named(RecordingIndicatorCorner.coordinateSpace))
    }
}
