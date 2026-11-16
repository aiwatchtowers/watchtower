import SwiftUI
import WatchtowerInterface

/// Reply… on a Waiting for me row (mockup §2d): Cancel and Propose, "Reply in #place", the text, and the note that
/// the reply goes to Needs approval. Propose sends `reply_propose` and closes; the proposal comes back as a Needs
/// approval card.
struct InboxReplySheet: View {
    let center: InboxCenter
    let cardID: String
    let row: InboxRefRowModel
    let place: String
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(center: InboxCenter, cardID: String, row: InboxRefRowModel, place: String, text: String = "") {
        self.center = center
        self.cardID = cardID
        self.row = row
        self.place = place
        _text = State(initialValue: text)
    }

    /// Propose needs words.
    static func canPropose(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(InboxText.replyIn(place)).font(TypeScale.rowEmphasis)
                TextEditor(text: $text)
                    .focused($focused)
                    .font(TypeScale.rowTitle)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.regular)
                    .frame(height: 140)
                    .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                Text(InboxText.replyNote)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(Spacing.large)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(InboxText.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(InboxText.propose, action: propose).disabled(!Self.canPropose(text))
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func propose() {
        let (center, cardID, row, text) = (center, cardID, row, text)
        Task { await Self.send(text, center: center, cardID: cardID, row: row) }
        dismiss()
    }

    /// Propose: `reply_propose` with the text, on the row (a refusal such as reply_waiting shows there).
    static func send(_ text: String, center: InboxCenter, cardID: String, row: InboxRefRowModel) async {
        await center.press(InboxPressKey.reply(cardID: cardID, row: row.key), on: row.key, hides: false) { requestID in
            row.replyRequest(text: text, cardID: cardID, requestID: requestID)
        }
    }
}
