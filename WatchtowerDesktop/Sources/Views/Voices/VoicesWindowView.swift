import SwiftUI
import WatchtowerCore

/// The Voices window: the owner's voice-labeling queue (Task 12), plus the
/// Review (Task 13) and Train (Task 14) screens behind the same segmented
/// control. Reads/writes go entirely through the app-wide
/// `AppState.voiceRegistryCenter`, so the queue survives the window closing
/// and reopening.
struct VoicesWindowView: View {
    static let sceneID = "voices"

    @Environment(AppState.self) private var appState
    /// View-local, not AppState-owned: a clip preview belongs to whichever
    /// card is on screen right now and has no state worth surviving
    /// navigation away from this window (the `ClipPlayer` doc comment).
    @State private var clipPlayer = ClipPlayer()

    private var center: VoiceRegistryCenter { appState.voiceRegistryCenter }

    /// Segmented-control case for `center.mode`, dropping `.queue`'s
    /// transcript scope — switching segments always means "the whole queue".
    private enum Segment: Hashable {
        case queue, review, train
    }

    private var segment: Segment {
        switch center.mode {
        case .queue: return .queue
        case .review: return .review
        case .train: return .train
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: segmentBinding) {
                Text("Queue").tag(Segment.queue)
                Text("Review").tag(Segment.review)
                Text("Train").tag(Segment.train)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            if let error = center.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch center.mode {
        case .queue:
            queue
        case .review:
            VoiceReviewView()
        case .train:
            VoiceTrainView()
        }
    }

    @ViewBuilder
    private var queue: some View {
        if center.cards.isEmpty {
            Text("No voices to label")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(center.cards) { card in
                        VoiceCardView(
                            card: card,
                            // Keyboard shortcuts belong to the first card
                            // only; confirming it promotes the next one.
                            isActive: card.id == center.cards.first?.id,
                            isPlaying: { clip in clipPlayer.isPlaying(url: URL(fileURLWithPath: card.audioPath), span: clip) },
                            onPlay: { clip in clipPlayer.toggle(url: URL(fileURLWithPath: card.audioPath), span: clip) },
                            onConfirm: { person in Task { await center.confirm(card, person: person) } },
                            onDismiss: { kind in Task { await center.dismiss(card, kind) } }
                        )
                    }
                }
                .padding(12)
            }
            .modifier(ClipPlayerErrorInset(player: clipPlayer))
        }
    }

    private var segmentBinding: Binding<Segment> {
        Binding(
            get: { segment },
            set: { newValue in
                Task {
                    switch newValue {
                    case .queue: await center.open(.queue(transcriptID: nil))
                    case .review: await center.open(.review)
                    case .train: await center.open(.train)
                    }
                }
            }
        )
    }
}
