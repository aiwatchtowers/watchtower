import SwiftUI
import UIKit
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// What a feed row asks the screen to do.
struct ChatFeedRowActions {
    var toggleSteps: (Int64) -> Void = { _ in }
    var openArtifact: (String) -> Void = { _ in }
    var openSources: ([ChatFeed.Source]) -> Void = { _ in }
    var regenerate: (Int64) -> Void = { _ in }
    var selectBranch: (ChatFeed.Message, Int) -> Void = { _, _ in }
    var edit: (Int64, String) -> Void = { _, _ in }
    var askAbout: (String) -> Void = { _ in }
    var loadEarlier: () -> Void = {}
    var answer: (ChatFeed.Action, ChatActionDecision) -> Void = { _, _ in }
}

/// The owner's bubble (mockups 2a, 2b): attachments above the text — a tile for an image, a pill for a file —, dim
/// while the send is on its way; long-press → Copy, Edit.
struct ChatOwnerBubble: View {
    static let sendingCaption = "Sending…"

    let owner: ChatFeedItem.Owner
    let actions: ChatFeedRowActions

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.small) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                if !owner.attachments.isEmpty {
                    HStack(spacing: Spacing.small) {
                        ForEach(owner.attachments) { pill in
                            if pill.isImage {
                                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                                    .fill(Color.white.opacity(PhoneOpacity.thumbTint))
                                    .frame(width: PhoneMetrics.chatThumb, height: PhoneMetrics.chatThumb)
                                    .overlay { Image(systemName: "photo").foregroundStyle(.white) }
                                    .accessibilityLabel(pill.name)
                            } else {
                                Label(pill.name, systemImage: "doc")
                                    .font(TypeScale.meta)
                                    .lineLimit(1)
                                    .padding(.horizontal, Spacing.compact)
                                    .padding(.vertical, Spacing.small)
                                    .background(Color.white.opacity(PhoneOpacity.thumbTint), in: RoundedRectangle(cornerRadius: Radius.row))
                            }
                        }
                    }
                }
                if !owner.text.isEmpty {
                    Text(ChatBubble.markdown(owner.text, role: .owner)).font(TypeScale.rowTitle)
                }
            }
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.regular)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .contextMenu {
                Button { UIPasteboard.general.string = owner.text } label: { Label(ChatFeedItems.copy, systemImage: "doc.on.doc") }
                if owner.canEdit, let id = owner.messageID {
                    Button { actions.edit(id, owner.text) } label: { Label(ChatFeedItems.edit, systemImage: "pencil") }
                }
            }
            if owner.isPending {
                Text(Self.sendingCaption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Spacing.hero)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(owner.isPending ? PhoneOpacity.pending : 1)
    }
}

/// One answer (mockups 2a–2f): the steps line, the text and its artifact cards, the sources chip, the error card,
/// and under the last answer ‹ i/n ›, Regenerate and Copy.
struct ChatAnswerView: View {
    let answer: ChatFeedItem.Answer
    let expanded: Bool
    let canAct: Bool
    let actions: ChatFeedRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let steps = answer.steps { stepsRow(steps) }
            ForEach(answer.segments) { segment in
                switch segment {
                case let .markdown(_, text):
                    ChatMarkdownView(text: text)
                case let .artifact(card):
                    artifactCard(card)
                }
            }
            if answer.isStreaming, !answer.message.text.isEmpty {
                RoundedRectangle(cornerRadius: Radius.mark / 2)
                    .fill(answer.isElsewhere ? Color.secondary : Color.accentColor)
                    .frame(width: Spacing.compact, height: Spacing.medium)
                    .accessibilityHidden(true)
            }
            if !answer.sources.isEmpty, !answer.isStreaming {
                Button { actions.openSources(answer.sources) } label: {
                    Text(ChatFeedItems.sourcesLabel(answer.sources.count))
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.regular)
                        .padding(.vertical, Spacing.small)
                        .background(Fill.card, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let error = answer.error { errorCard(error) }
            if answer.isLast, !answer.isStreaming, answer.error == nil { footer }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button { UIPasteboard.general.string = answer.message.text } label: { Label(ChatFeedItems.copy, systemImage: "doc.on.doc") }
            if answer.message.status == "complete" {
                Button { actions.askAbout(answer.message.text) } label: { Label(ChatFeedItems.askAboutThis, systemImage: "text.quote") }
            }
        }
    }

    private func stepsRow(_ steps: ChatFeedItem.Steps) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button { actions.toggleSteps(answer.message.id) } label: {
                HStack(spacing: Spacing.compact) {
                    switch steps.mark {
                    case .running: ProgressView().controlSize(.mini)
                    case .done: Image(systemName: "checkmark").foregroundStyle(PhoneTone.green.color)
                    case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(PhoneTone.red.color)
                    }
                    Text(steps.line).lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(TypeScale.badge)
                }
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(steps.steps.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(step.name).font(TypeScale.code)
                        if !step.summary.isEmpty { Text(step.summary).font(TypeScale.meta).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, Spacing.large)
                }
            }
        }
    }

    private func artifactCard(_ card: ChatFeedItem.ArtifactCard) -> some View {
        Button { actions.openArtifact(card.key) } label: {
            HStack(spacing: Spacing.regular) {
                Image(systemName: card.symbol)
                    .frame(width: PhoneMetrics.chatArtifactIcon, height: PhoneMetrics.chatArtifactIcon)
                    .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(card.title).font(TypeScale.rowEmphasis).foregroundStyle(.primary)
                    Text(card.kindLabel).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(Spacing.cozy)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorCard(_ error: ChatFeedItem.ErrorCard) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Text(ChatFeedItem.ErrorCard.title).font(TypeScale.rowEmphasis).foregroundStyle(PhoneTone.red.color)
            Text(error.line).font(TypeScale.meta).foregroundStyle(.secondary)
            if error.retryable {
                Button(ChatFeedItem.ErrorCard.retry) { actions.regenerate(answer.message.id) }
                    .buttonStyle(ChatCardButtonStyle(fill: Fill.card, label: .primary))
                    .disabled(!canAct)
                    .padding(.top, Spacing.small)
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.card, in: shape)
        .overlay(shape.strokeBorder(PhoneTone.red.color, lineWidth: Stroke.hairline))
    }

    private var footer: some View {
        let siblings = answer.message.siblings
        return HStack(spacing: Spacing.medium) {
            if siblings.count > 1 {
                HStack(spacing: Spacing.small) {
                    Button { actions.selectBranch(answer.message, -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(siblings.neighbour(-1) == nil)
                    Text("\(siblings.index)/\(siblings.count)").monospacedDigit()
                    Button { actions.selectBranch(answer.message, 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(siblings.neighbour(1) == nil)
                }
            }
            Button { actions.regenerate(answer.message.id) } label: { Label(ChatFeedItems.regenerate, systemImage: "arrow.clockwise") }
                .disabled(!canAct)
            Button { UIPasteboard.general.string = answer.message.text } label: { Label(ChatFeedItems.copy, systemImage: "doc.on.doc") }
        }
        .font(TypeScale.meta)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }
}

/// "Load earlier messages" at the top (mockup 2i); its own wait, and "did not answer" with Retry.
struct ChatEarlierRow: View {
    let state: ChatConversationModel.Earlier
    let host: TowerHost
    let load: () -> Void

    var body: some View {
        Group {
            switch state {
            case .more:
                Button(ChatFeedItems.loadEarlier, action: load).font(TypeScale.meta)
            case .loading:
                ProgressView()
            case .noAnswer:
                VStack(spacing: Spacing.small) {
                    Text(ChatText.noAnswer(host)).font(TypeScale.meta).foregroundStyle(.secondary)
                    Button(ChatsGateModel.retry, action: load).font(TypeScale.meta)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch)
    }
}

/// The passage picker behind Ask about this (mockup 2i): the answer as selectable text; the selection goes to the
/// quote batch.
struct ChatQuotePicker: View {
    static let hint = "Select the part you want to ask about."

    let text: String
    let pick: (String) -> Void
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(Self.hint).font(TypeScale.meta).foregroundStyle(.secondary).padding(.horizontal, Spacing.large)
                SelectableText(text: text, selection: $selection)
            }
            .navigationTitle(ChatFeedItems.askAboutThis)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChatFeedItems.askAboutThis) {
                        if let selection { pick(selection) }
                        dismiss()
                    }
                    .disabled(selection == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChatRowActions.renameCancel) { dismiss() }
                }
            }
        }
    }
}

/// A read-only UITextView reporting its selected passage (`ChatQuoteReply.selectedText`, the Mac's rule).
private struct SelectableText: UIViewRepresentable {
    let text: String
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .callout)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: Spacing.regular, left: Spacing.medium, bottom: Spacing.regular, right: Spacing.medium)
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let selection: Binding<String?>

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection.wrappedValue = ChatQuoteReply.selectedText(textView.text, selection: textView.selectedRange)
        }
    }
}
