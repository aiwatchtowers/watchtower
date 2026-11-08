import SwiftUI
import WatchtowerCore

/// The Reviewer side of Branch review's chat panel (board #1025, mockup
/// frame 5): what the reviewer reads, then its thread for the branch on the
/// shared embedded chat — a failed turn shows its error with Retry, as in
/// every embedded chat — and Send to author under each answer.
struct ReviewerPanel: View {
    let center: ReviewerCenter
    let model: ReviewChangesModel
    /// nil until the thread key is known (no round yet, branch not read yet).
    let context: ReviewerSurface.Context?

    var body: some View {
        if let context {
            let id = ReviewerCenter.ThreadID(projectID: context.projectID, branch: context.branch)
            VStack(spacing: 0) {
                Text(ReviewerSurface.mapLine(context))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.small)
                Divider()
                thread(id: id, context: context)
            }
            .task(id: id) { await center.open(id) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func thread(id: ReviewerCenter.ThreadID, context: ReviewerSurface.Context) -> some View {
        switch center.threads[id] {
        case let .ready(conversationID):
            let engine = center.engine(context: context, conversationID: conversationID) { [model] in
                model.reviewerMapInput
            }
            EmbeddedChatView(
                engine: engine, density: .compact, placeholder: ReviewerSurface.placeholder,
                accessory: { item in
                    ReviewerAnswerActions(center: center, model: model, item: item,
                                          isLive: engine.liveTurn?.messageID == item.id)
                },
                footer: { EmptyView() }
            )
            .embeddedChatVisibility(engine.spec.key, in: center.embeddedChats)
        case let .failed(message):
            VStack(spacing: Spacing.regular) {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await center.open(id) } }
                    .buttonStyle(.kitSecondary)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Send to author under a finished answer, or the line saying where it went.
struct ReviewerAnswerActions: View {
    let center: ReviewerCenter
    let model: ReviewChangesModel
    let item: ChatThreadItem
    let isLive: Bool

    static func offers(_ item: ChatThreadItem, isLive: Bool) -> Bool {
        item.message.role == "assistant" && item.message.status == "complete" && !isLive
            && !item.message.text.isEmpty
    }

    var body: some View {
        if Self.offers(item, isLive: isLive) {
            if let roundID = center.sent[item.id] {
                Label(ReviewerCenter.sentLine(roundID: roundID), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.cozy) {
                        Button("Send to author") {
                            Task { await center.send(messageID: item.id, text: item.message.text, to: model) }
                        }
                        .buttonStyle(.kitSecondary)
                        .controlSize(.small)
                        .disabled(!model.canSendToAuthor || center.sending.contains(item.id))
                        .help(model.canSendToAuthor
                              ? "Adds this answer as a design comment to the open round"
                              : ReviewerCenter.startRoundToSend)
                        if !model.canSendToAuthor {
                            Text(ReviewerCenter.startRoundToSend)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = center.sendErrors[item.id] {
                        Text(error).font(.caption).foregroundStyle(Tone.warning)
                    }
                }
            }
        }
    }
}
