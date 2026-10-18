import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// "Tell the session…": a line to an idle session (PROJ-16). At a
/// permission prompt it sends nothing and says so.
struct TellSessionBar: View {
    let model: SessionInputModel
    let isSending: Bool
    let onSend: (String) async -> Bool
    @State private var text = ""

    var body: some View {
        BottomActionBar {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.regular) {
                    TextField("Tell the session…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Message to the session")
                    if model.canSend {
                        Button {
                            Task {
                                if await onSend(text) { text = "" }
                            }
                        } label: {
                            Image(systemName: "arrow.right")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || !SessionInputText.isSendable(text))
                        .accessibilityLabel("Send")
                    }
                }
                Text(model.approvalText ?? SessionInputModel.footnote)
                    .font(.caption)
                    .foregroundStyle(model.approvalText == nil ? Color.secondary : PhoneTone.waitingForYou.color)
            }
        }
    }
}
