import Foundation

/// The editor's Look step (Inbox builder A, spec "The Look step" → States):
/// turns the text on screen, the recipe's outputs, the newest chat draft,
/// the owner's newest Dry run and the press in flight into the one state
/// the pane shows. Pure; `AutomationEditorCenter` keeps the owner's runs.
package enum AutomationLookPreviewModel {
    /// One dry run of one text: the chat's `draft_automation` (a draft-cache
    /// entry) or the owner's **Dry run** (`automations preview`). Both carry
    /// the same `DraftResult` shape.
    package struct Run: Equatable, Sendable {
        package enum Outcome: Equatable, Sendable {
            case result(AutomationDraftEntry.Result)
            /// The evaluation did not finish: the CLI failed, its output did
            /// not decode, or the chat's draft tool returned an error.
            case failure(String)
        }

        /// The exact recipe text the run evaluated.
        package let text: String
        package let at: Date
        package let outcome: Outcome

        package init(text: String, at: Date, outcome: Outcome) {
            self.text = text
            self.at = at
            self.outcome = outcome
        }

        /// A chat draft-cache entry as a run; an entry without its time is
        /// older than any owner run.
        package init(entry: AutomationDraftEntry) {
            text = entry.recipeText
            at = entry.at ?? .distantPast
            outcome = entry.result.map(Outcome.result)
                ?? .failure(entry.error.map { "Couldn't check this draft: \($0)" } ?? "Couldn't check this draft.")
        }
    }

    /// How many of the journal's last steps a failed run shows.
    package static let failedStepLimit = 5
    package static let notDryRunLine = "The recipe was checked but not dry-run."
    package static let stoppedWithoutCards = "The dry run stopped before it made a card."

    /// The chat entry the pane compares: the newest entry of `text`, else
    /// the newest entry of any text (a stale preview). Entries come oldest
    /// first (`AutomationDraftCacheQueries.entries`); undecodable ones are
    /// skipped.
    package static func chatEntry(in entries: [String], text: String) -> AutomationDraftEntry? {
        let decoded = entries.compactMap { try? JSONDecoder().decode(AutomationDraftEntry.self, from: Data($0.utf8)) }
        return decoded.last { $0.recipeText == text } ?? decoded.last
    }

    /// The pane's state. `outputs` is the recipe's declared outputs, nil
    /// while not known (no check yet): then the pane does not claim the
    /// recipe has no Inbox output. `selected` is the picker's card.
    package static func state(
        text: String,
        outputs: [String]?,
        chatEntry: AutomationDraftEntry?,
        ownerResult: Run?,
        running: Bool,
        selected: Int = 0
    ) -> AutomationLookPaneContent {
        if let outputs, !outputs.contains("inbox") { return .noInboxOutput }
        let runs = [chatEntry.map(Run.init(entry:)), ownerResult].compactMap { $0 }
        let current = newest(runs.filter { $0.text == text })
        let settled: AutomationLookPaneContent
        if let current {
            settled = state(of: current, selected: selected)
        } else if let other = newest(runs), let shown = cards(of: other, selected: selected), !shown.cards.isEmpty {
            settled = .stale(shown)
        } else {
            settled = .empty
        }
        guard running else { return settled }
        return .running(previous: shownCards(settled))
    }

    /// The newer run; on a tie the owner's (listed last).
    private static func newest(_ runs: [Run]) -> Run? {
        runs.reduce(nil) { best, run in
            guard let best else { return run }
            return run.at >= best.at ? run : best
        }
    }

    private static func state(of run: Run, selected: Int) -> AutomationLookPaneContent {
        let result: AutomationDraftEntry.Result
        switch run.outcome {
        case let .failure(message):
            return .failed(message: message, steps: [])
        case let .result(value):
            result = value
        }
        guard result.ok else {
            return .failed(message: result.errors.joined(separator: "\n"), steps: [])
        }
        guard let dryRun = result.dryRun else { return .failed(message: notDryRunLine, steps: []) }
        let shown = cards(dryRun, selected: selected)
        switch dryRun.status {
        case "succeeded":
            guard !shown.cards.isEmpty else { return .noCard(tokens: Int(dryRun.tokens)) }
            return .preview(shown, tokens: Int(dryRun.tokens), at: run.at)
        case "stopped":
            return .stopped(shown)
        case "refused":
            // D16: an unconfirmed recipe the chat may not dry-run; its line, not a preview.
            return .failed(message: dryRun.error, steps: [])
        default:
            let message = dryRun.error.isEmpty ? "The dry run ended: \(dryRun.status)." : dryRun.error
            let steps = dryRun.steps.suffix(failedStepLimit).map(AutomationDraftPanelModel.runStep)
            return .failed(message: message, steps: DryRunPresentation.lines(steps: steps))
        }
    }

    /// A run's Inbox cards, nil when it made none it could show (it failed).
    private static func cards(of run: Run, selected: Int) -> AutomationLookPaneContent.Shown? {
        guard case let .result(result) = run.outcome, let dryRun = result.dryRun else { return nil }
        return cards(dryRun, selected: selected)
    }

    private static func cards(_ dryRun: AutomationDraftEntry.DryRun, selected: Int) -> AutomationLookPaneContent.Shown {
        let cards = dryRun.outputs.filter { $0.kind == "inbox" }.map { output in
            AutomationLookPaneContent.Card(
                title: output.title,
                priority: output.priority.isEmpty ? "normal" : output.priority,
                key: output.key,
                blocksJSON: output.blocksJSON,
                body: output.body,
                actionsJSON: output.actionsJSON
            )
        }
        return AutomationLookPaneContent.Shown(cards: cards, selected: min(max(selected, 0), max(cards.count - 1, 0)))
    }

    /// The cards a settled state shows, which `running` dims.
    private static func shownCards(_ state: AutomationLookPaneContent) -> AutomationLookPaneContent.Shown? {
        switch state {
        case let .preview(shown, _, _), let .stale(shown), let .stopped(shown):
            return shown.cards.isEmpty ? nil : shown
        default:
            return nil
        }
    }
}
