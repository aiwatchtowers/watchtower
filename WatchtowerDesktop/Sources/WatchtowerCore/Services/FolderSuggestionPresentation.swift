import Foundation

/// The agent's folder suggestion (#2003, spec 2026-11-18-multi-folder-workbench
/// §6.7): the card in "Waiting for you" and the answer lines the agent reads
/// with `get_ask`. Pure: the view model hands in the ask and where the card
/// is, the view draws what comes back.
package enum FolderSuggestionPresentation {
    /// Where a card is: offering its three answers, adding the folder, or
    /// showing why the add failed (until `OK`).
    package enum Phase: Equatable, Sendable {
        case ready
        case busy
        /// The failure line (`failed(name:reason:)`), shown on the card;
        /// the agent has it as its answer.
        case failed(String)
        /// The failure line whose answer could not be saved: `Retry`
        /// sends it again; no `OK` until it is saved.
        case unsent(String)
    }

    /// What one card shows.
    package struct Card: Equatable, Sendable {
        package let title: String
        /// The suggestion's origin, or in `.failed` the failure line.
        package let subtitle: String
        package let phase: Phase
        /// The bench the folder is on now, when it is another one's (the
        /// merge variant of the card is §6.13's); nil otherwise.
        package let otherBench: String?
    }

    package static let icon = "plus.rectangle.on.folder"
    package static let putOnBench = "Put on Bench"
    package static let notNow = "Not Now"
    package static let never = "Never for This Folder"
    package static let busy = "Putting on the bench…"
    package static let ok = "OK"
    /// Sends a failure answer that was not saved, again.
    package static let retry = "Retry"
    /// The TCC warning's cancel on a card (Put on Bench was the only folder).
    package static let cancel = "Cancel"

    /// The folder's name as the card says it: the last path component.
    package static func folderName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    package static func title(name: String) -> String {
        "Put \(name) on the bench?"
    }

    /// `From “<session>” · the agent worked in <path> <n> times`. Without a
    /// session (deleted since, or filed outside the app) the origin part is
    /// left out; without counted touches (a Codex session asks by itself,
    /// spec §6.7) so is the count.
    package static func subtitle(
        sessionTitle: String?, path: String, touches: Int, home: String = NSHomeDirectory()
    ) -> String {
        let shown = WorkbenchFolderPresentation.abbreviated(path, home: home)
        let worked: String
        switch touches {
        case ..<1: worked = "the agent worked in \(shown)"
        case 1: worked = "the agent worked in \(shown) 1 time"
        default: worked = "the agent worked in \(shown) \(touches) times"
        }
        guard let sessionTitle, !sessionTitle.isEmpty else { return worked.prefix(1).uppercased() + worked.dropFirst() }
        return "From “\(sessionTitle)” · \(worked)"
    }

    /// The card's failure line, and the agent's answer after a failed add.
    package static func failed(name: String, reason: String) -> String {
        WorkbenchFolderPresentation.putOnBenchFailed(name: name, reason: reason)
    }

    /// `otherBench`: the bench the folder turned out to be on when Put on
    /// Bench ran (F14), else the one the suggestion was filed with. On
    /// another bench the card is the merge variant (§6.13, mockup
    /// `suggest-card-merge`): its line reads `<name> is on the “<B>” bench`,
    /// its buttons `Merge Benches…` · `Not Now`.
    package static func card(
        _ suggestion: FolderSuggestionPayload,
        sessionTitle: String?,
        phase: Phase,
        otherBench: FolderSuggestionPayload.OtherBench? = nil,
        home: String = NSHomeDirectory()
    ) -> Card {
        let name = folderName(suggestion.path)
        let bench = (otherBench ?? suggestion.otherBench)?.name
        switch phase {
        case let .failed(line), let .unsent(line):
            return Card(title: title(name: name), subtitle: line, phase: phase, otherBench: bench)
        case .ready, .busy:
            let subtitle = bench.map { BenchMergePresentation.cardLine(name: name, bench: $0) }
                ?? Self.subtitle(sessionTitle: sessionTitle, path: suggestion.path, touches: suggestion.touches, home: home)
            return Card(title: title(name: name), subtitle: subtitle, phase: phase, otherBench: bench)
        }
    }

    // MARK: Answer lines (the ask's note, read with get_ask)

    /// Put on Bench added the folder (or found it already on the bench);
    /// `name` is its stored name, the one `start_session` takes.
    package static func addedAnswer(name: String) -> String {
        "\(name) is on the bench now. Start a sub-session there with start_session(\"\(name)\", …)."
    }

    package static let notNowAnswer = "The owner said not now."

    package static func neverAnswer(name: String) -> String {
        "The owner does not want \(name) on this bench."
    }
}
