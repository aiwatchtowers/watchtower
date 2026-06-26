import SwiftUI

// MARK: - Chat Section

struct TargetChatSection: View {
    @Bindable var chatVM: TargetChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assistant")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if chatVM.isStreaming {
                    Button("Stop") { chatVM.cancelStream() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chatVM.messages.isEmpty {
                        Text("Ask AI to work on this task…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding()
                    }
                    ForEach(chatVM.messages) { msg in
                        chatBubble(msg)
                        ForEach(chatVM.actionCards.filter { $0.messageID == msg.id }) { card in
                            TargetActionCardView(
                                card: card,
                                isStreaming: chatVM.isStreaming,
                                onApprove: { chatVM.approve(card) },
                                onReject: { chatVM.reject(card) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask AI to work on this task…", text: $chatVM.inputText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .onSubmit { chatVM.send() }

                Button { chatVM.send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(
                    chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || chatVM.isStreaming
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let err = chatVM.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer()
                Text(msg.text)
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if msg.text.isEmpty && msg.isStreaming {
                        Text("Thinking...")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    } else {
                        MarkdownText(text: msg.text)
                            .font(.subheadline)
                    }
                    if msg.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                Spacer()
            }
        case .system:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Action Card

struct TargetActionCardView: View {
    let card: TargetActionCard
    /// Disable Approve/Reject while a turn is streaming: a decision taken mid-stream
    /// would apply the write but its follow-up is dropped (sendFollowUp guards on isStreaming).
    let isStreaming: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.action.cardDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            switch card.state {
            case .pending:
                HStack(spacing: 8) {
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Reject", action: onReject)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .disabled(isStreaming)
            case .applied(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .rejected:
                Label("Rejected", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let err):
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.3)))
    }
}
