import SwiftUI
import WatchtowerCore

// MARK: - View

/// The track's chat, docked at the bottom of the track detail split.
struct TrackChatSection: View {
    let engine: EmbeddedChatEngine
    let trackID: Int

    var body: some View {
        EmbeddedChatView(engine: engine, density: .compact, placeholder: "Ask about this track…",
                         dictationTargetID: "chat.track.\(trackID)")
            // The track pane's bottom-most content.
            .clearsRecordingIndicator()
    }
}
