import DesignKit
import SwiftUI
import WatchtowerCore

/// The connect assistant (agent connect spec §5.2, §7): a 380 pt panel on
/// the right of the Connections tab, in the `SetupAssistantPanel` slot. A
/// header with the harness picker, the mode line, the chat, the state's
/// card or status line with its buttons, and the composer. Every string is
/// `ConnectAssistantPresentation`'s.
///
/// With an `engine` the chat is the shared embedded chat (compact), and the
/// state's card, status and buttons sit in its footer above the composer;
/// without one (the design shots) `lines` stand in for it.
struct ConnectAssistantPanel: View {
    static let width: CGFloat = 380

    let presentation: ConnectAssistantPresentation
    /// The offered harnesses (`ConnectHarnessCatalog.offered(...).harnesses`), for the header's picker.
    let harnesses: [ConnectHarness]
    var lines: [ConnectAssistantLine] = []
    /// The run's chat; nil before the first run (and in the design shots).
    var engine: EmbeddedChatEngine?
    /// A run is under way: the composer takes questions.
    var acceptsQuestions = true
    var onHarness: (ConnectHarness) -> Void = { _ in }
    var onAction: (ConnectAssistantPresentation.Action) -> Void = { _ in }
    /// The secret card's value: handed to the Desktop flow, never to the chat.
    var onSecret: (String) -> Void = { _ in }
    /// The secret card closed without a value: the agent hears `cancelled`.
    var onSecretDismiss: () -> Void = {}
    var onConfirm: (Bool) -> Void = { _ in }
    var onAsk: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var secret = ""
    @State private var question = ""

    private typealias Pres = ConnectAssistantPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let engine {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    modeLine
                    if let intro = presentation.intro { assistantLine(intro) }
                }
                .padding(.horizontal, Spacing.medium)
                EmbeddedChatView(
                    engine: engine, density: .compact, placeholder: presentation.composerPlaceholder,
                    showsComposer: acceptsQuestions,
                    accessory: { _ in EmptyView() },
                    footer: {
                        stateArea
                            .padding(.horizontal, Spacing.medium)
                            .padding(.bottom, Spacing.regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
                if !acceptsQuestions { composer }
            } else {
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
                        stateArea
                    }
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                composer
            }
        }
        .controlSize(.small)
        .frame(width: Self.width)
        .panelBackground()
        // A new card starts empty: a value typed into an earlier one is gone.
        .onChange(of: presentation.card) { secret = "" }
    }

    /// The state's card, status line and buttons.
    @ViewBuilder private var stateArea: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let card = presentation.card { cardView(card) }
            if let status = presentation.status { statusRow(status) }
            if !presentation.actions.isEmpty { actionRow }
        }
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
            .help(presentation.helpText)
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
                HStack(spacing: Spacing.regular) {
                    Label(secretCard.label, systemImage: "key")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: Spacing.regular)
                    Button(action: dismissSecret) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.kitIcon(isOn: false))
                    .help(secretCard.dismiss)
                    .accessibilityLabel(secretCard.dismiss)
                }
                if let closeFirst = secretCard.closeFirst {
                    Text(closeFirst)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.regular) {
                    SecureField(secretCard.placeholder, text: $secret)
                        .textFieldStyle(.kit)
                        .onSubmit(sendSecret)
                        .onExitCommand(perform: dismissSecret)
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
        let value = secret
        secret = ""
        onSecret(value)
    }

    private func dismissSecret() {
        secret = ""
        onSecretDismiss()
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

    /// The panel's own composer: the design shots' and, with no run under
    /// way, a disabled stand-in for the chat's.
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
        .disabled(!acceptsQuestions)
        .padding(Spacing.medium)
    }
}

/// The panel over a live session (`AppState.connectAssistants`): its
/// buttons and cards answer through the session and its run's controller.
struct ConnectAssistantHost: View {
    @Environment(AppState.self) private var appState
    let session: ConnectAssistantSession

    var body: some View {
        let state = session.state
        ConnectAssistantPanel(
            presentation: session.presentation,
            harnesses: session.harnesses,
            engine: session.engine,
            acceptsQuestions: Self.acceptsQuestions(state),
            onHarness: { session.switchHarness($0) },
            onAction: perform,
            onSecret: { session.controller?.sendSecret($0) },
            onSecretDismiss: { session.controller?.cancelSecret() },
            onConfirm: { session.controller?.answerConfirm($0) },
            onAsk: { session.engine?.send($0) },
            onClose: { appState.closeConnectAssistant() }
        )
        .id(session.service)
    }

    /// The composer takes questions only while a run is under way: before
    /// Start, after a failure (Retry starts the next) and while another
    /// window holds the sign-in, a question would reach no run.
    static func acceptsQuestions(_ state: ConnectAssistantState) -> Bool {
        switch state {
        case .empty, .failed, .busy: false
        case .thinking, .listening, .waiting, .secret, .confirm, .done: true
        }
    }

    private func perform(_ action: ConnectAssistantPresentation.Action) {
        switch action {
        case .start: session.start()
        case .guideInWords: session.guideInWords()
        case .retry: session.retry()
        case .cancel: session.cancel()
        case .setUpByHand: appState.connectAssistantSetUpByHand(service: session.service)
        case .openIt: appState.connectAssistantOpenOther(service: session.service)
        }
    }
}
