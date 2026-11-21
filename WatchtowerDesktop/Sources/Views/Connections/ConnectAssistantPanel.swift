import DesignKit
import SwiftUI
import WatchtowerCore

/// The connect assistant (agent connect spec §5.2, §7): a 380 pt panel on
/// the right of the Connections tab, in the `SetupAssistantPanel` slot. A
/// header with the harness picker, the mode line, the chat, the state's
/// card or status line with its buttons, and the composer. Every string is
/// `ConnectAssistantPresentation`'s.
///
/// Design stage: the chat lines are plain rows here; the built panel hosts
/// the shared embedded chat (`EmbeddedChatView`, compact) in their place.
struct ConnectAssistantPanel: View {
    static let width: CGFloat = 380

    let presentation: ConnectAssistantPresentation
    let lines: [ConnectAssistantLine]
    /// The offered harnesses (`ConnectHarnessCatalog.offered`), for the header's picker.
    var harnesses: [ConnectHarness] = []
    var onHarness: (ConnectHarness) -> Void = { _ in }
    var onAction: (ConnectAssistantPresentation.Action) -> Void = { _ in }
    /// The secret card's value: handed to the Desktop flow, never to the chat.
    var onSecret: (String) -> Void = { _ in }
    var onConfirm: (Bool) -> Void = { _ in }
    var onAsk: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var secret = ""
    @State private var question = ""

    private typealias Pres = ConnectAssistantPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    modeLine
                    if let intro = presentation.intro { assistantLine(intro) }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        switch line.role {
                        case .assistant: assistantLine(line.text)
                        case .customer: customerLine(line.text)
                        }
                    }
                    if let card = presentation.card { cardView(card) }
                    if let status = presentation.status { statusRow(status) }
                    if !presentation.actions.isEmpty { actionRow }
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.bottom, Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .controlSize(.small)
        .frame(width: Self.width)
        .panelBackground()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text(presentation.title)
                .font(.headline)
            Spacer()
            Menu {
                ForEach(harnesses, id: \.self) { harness in
                    Button(harness.name) { onHarness(harness) }
                }
            } label: {
                MenuLabel(text: presentation.harness, systemImage: "cpu", color: .secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Pres.switchHarness)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.kitIcon(isOn: false))
            .help(Pres.close)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    private var modeLine: some View {
        Label(presentation.modeLine, systemImage: presentation.wordsOnly ? "text.bubble" : "globe")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Chat

    private func assistantLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func customerLine(_ text: String) -> some View {
        HStack {
            Spacer(minLength: Spacing.hero)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.cozy)
                .padding(.vertical, Spacing.compact)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.bubble))
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func cardView(_ card: Pres.Card) -> some View {
        switch card {
        case .secret(let secretCard):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Label(secretCard.label, systemImage: "key")
                    .font(.callout.weight(.semibold))
                HStack(spacing: Spacing.regular) {
                    SecureField(secretCard.placeholder, text: $secret)
                        .textFieldStyle(.kit)
                        .onSubmit(sendSecret)
                    Button(secretCard.send, action: sendSecret)
                        .buttonStyle(.kitPrimary)
                        .disabled(secret.isEmpty)
                }
                Label(secretCard.footnote, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.medium)
            .card()
        case .confirm(let confirmCard):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(confirmCard.question)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Label(confirmCard.detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                HStack(spacing: Spacing.regular) {
                    Button(confirmCard.confirm) { onConfirm(true) }
                        .buttonStyle(.kitPrimary)
                    Button(confirmCard.cancel) { onConfirm(false) }
                        .buttonStyle(.kitSecondary)
                }
                Text(confirmCard.footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func ask() {
        guard !question.isEmpty else { return }
        onAsk(question)
        question = ""
    }

    private func sendSecret() {
        guard !secret.isEmpty else { return }
        onSecret(secret)
        secret = ""
    }

    // MARK: Status and actions

    private func statusRow(_ status: Pres.Status) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            switch status.kind {
            case .progress:
                ProgressView().controlSize(.mini)
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
            }
            Text(status.text)
                .font(.callout)
                .foregroundStyle(status.kind == .progress ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.regular) {
            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { index, action in
                actionButton(action, prominent: index == 0 && action != .cancel)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Pres.Action, prominent: Bool) -> some View {
        let button = Button(action.title) { onAction(action) }
        if prominent {
            button.buttonStyle(.kitPrimary)
        } else if action == .setUpByHand || action == .guideInWords {
            button.buttonStyle(.kitQuiet)
        } else {
            button.buttonStyle(.kitSecondary)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: Spacing.regular) {
            TextField(presentation.composerPlaceholder, text: $question)
                .textFieldStyle(.kit)
                .onSubmit(ask)
            Button(action: ask) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.kitIcon(isOn: false))
            .disabled(question.isEmpty)
        }
        .padding(Spacing.medium)
    }
}
