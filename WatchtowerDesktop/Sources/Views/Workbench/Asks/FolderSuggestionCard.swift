import SwiftUI
import WatchtowerCore

/// What a folder card's buttons do.
struct FolderSuggestionActions {
    var putOnBench: () -> Void = {}
    var notNow: () -> Void = {}
    var never: () -> Void = {}
    /// `OK` under a failed add.
    var done: () -> Void = {}
}

/// The agent's folder suggestion in "Waiting for you" (#2003, spec §6.7):
/// `Put <name> on the bench?`, where it comes from, then `Put on Bench` ·
/// `Not Now` on one line and the quiet `Never for This Folder` under them
/// (the panel is too narrow for three). While the add runs it says so; a
/// failed add shows its reason and `OK`.
struct FolderSuggestionCard: View {
    typealias Copy = FolderSuggestionPresentation

    let card: FolderSuggestionPresentation.Card
    /// Why the last answer or decline failed (the card stays answerable).
    var error: String?
    /// An answer is being written: the buttons wait.
    var answering = false
    var actions = FolderSuggestionActions()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Image(systemName: Copy.icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: IconSize.composer)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(card.title)
                    Text(card.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(Tone.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            buttons.padding(.leading, IconSize.composer + Spacing.compact)
        }
        .padding(Spacing.regular)
        .card(fill: Fill.selected)
        .help(card.title)
    }

    @ViewBuilder private var buttons: some View {
        switch card.phase {
        case .ready:
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.small) {
                    Button(Copy.putOnBench, action: actions.putOnBench).buttonStyle(.kitPrimary).fixedSize()
                    Button(Copy.notNow, action: actions.notNow).buttonStyle(.kitSecondary).fixedSize()
                }
                Button(Copy.never, action: actions.never).buttonStyle(.kitQuiet).fixedSize()
            }
            .controlSize(.small)
            .disabled(answering)
        case .busy:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text(Copy.busy).font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Button(Copy.ok, action: actions.done).buttonStyle(.kitSecondary).controlSize(.small)
        }
    }
}

/// A folder card bound to the asks: its phase and errors from
/// `OwnerAsksViewModel`, Put on Bench through Open Folder…'s TCC warning.
struct FolderSuggestionAskCard: View {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    let suggestion: FolderSuggestionPayload
    @State private var sensitiveLocation: String?

    var body: some View {
        let asks = vm.asks
        FolderSuggestionCard(
            card: FolderSuggestionPresentation.card(
                suggestion, sessionTitle: ask.sessionID.flatMap { vm.session($0, projectID: ask.projectID)?.title },
                phase: asks.folderPhases[ask.id] ?? .ready
            ),
            error: asks.answerErrors[ask.id],
            answering: asks.isAnswering(ask.id),
            actions: FolderSuggestionActions(
                putOnBench: putOnBench,
                notNow: { Task { await asks.notNow(ask) } },
                never: { Task { await asks.never(ask) } },
                done: { asks.folderCardDone(ask.id) }
            )
        )
        .sensitiveLocationAlert($sensitiveLocation, cancelLabel: FolderSuggestionPresentation.cancel) {
            Task { await asks.putSuggestedFolderOnBench(ask) }
        } onCancel: {}
    }

    private func putOnBench() {
        Task {
            if case let .confirmLocation(location) = await vm.asks.putOnBench(ask) { sensitiveLocation = location }
        }
    }
}
