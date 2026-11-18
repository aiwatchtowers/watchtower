import Foundation

/// Merging benches (#2003, spec 2026-11-18-multi-folder-workbench §6.13):
/// putting on bench A a folder that is on bench B offers to merge B into A.
/// Every line of the confirmation, the refusal and the suggestion card's
/// merge variant. Pure.
package enum BenchMergePresentation {
    // MARK: Confirmation

    package static func confirmTitle(from: String, into: String) -> String {
        "Merge “\(from)” into “\(into)”?"
    }

    /// `<B>'s board (<n> targets), asks and sessions move to <A>, and <B>
    /// leaves the workbench list. Folders that move: <list>.`
    /// When `dropped` is not empty one more line follows (ask #1598).
    package static func confirmText(
        from: String, into: String, targets: Int, folders: [String], dropped: [String] = []
    ) -> String {
        let count = targets == 1 ? "1 target" : "\(targets) targets"
        let text = "\(from)'s board (\(count)), asks and sessions move to \(into), and \(from) leaves the workbench list. "
            + "Folders that move: \(folders.joined(separator: ", "))."
        guard !dropped.isEmpty else { return text }
        return text + " " + droppedLine(from: from, into: into, dropped: dropped)
    }

    package static let sessionInstructionsName = "session instructions"
    package static let targetProcedureName = "target procedure"
    package static let worktreeSetupName = "worktree setup"

    /// The names of B's owner-written settings that hold something (blank
    /// ones do not count), in the order of the line.
    package static func droppedSettings(sessionInstructions: String?, targetProcedure: String?, worktreeSetup: String?) -> [String] {
        func present(_ value: String?) -> Bool {
            !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var names: [String] = []
        if present(sessionInstructions) { names.append(sessionInstructionsName) }
        if present(targetProcedure) { names.append(targetProcedureName) }
        if present(worktreeSetup) { names.append(worktreeSetupName) }
        return names
    }

    /// `“<B>”’s own <list> will be dropped; “<A>”’s stay.` The list joins
    /// with ", " and " and ".
    package static func droppedLine(from: String, into: String, dropped: [String]) -> String {
        let list = dropped.count > 1
            ? dropped.dropLast().joined(separator: ", ") + " and " + dropped[dropped.count - 1]
            : dropped.joined()
        return "“\(from)”’s own \(list) will be dropped; “\(into)”’s stay."
    }

    /// The merge is done but a step after it failed (the data moved anyway;
    /// a failed reinstall shows on its folder instead). Left to the builder.
    package static func partlyDone(from: String, steps: [String]) -> String {
        "Merged “\(from)”, but \(steps.joined(separator: " and ")) failed."
    }

    package static let imagesStep = "moving its target images"
    package static let searchStep = "updating search"

    /// The bench a merge was offered for (or into) is not on the list any more.
    package static let benchGone = "that workbench is not on the workbench list any more."

    package static let cancel = "Cancel"
    package static let merge = "Merge"

    // MARK: Refused (B has live sessions)

    package static func refusedTitle(from: String) -> String {
        "Can’t merge “\(from)” yet"
    }

    package static func refusedText(from: String, running: Int) -> String {
        running == 1
            ? "1 session is running in \(from). Finish it first."
            : "\(running) sessions are running in \(from). Finish them first."
    }

    package static let ok = "OK"

    /// A merge that failed for another reason, under the FILES header. The
    /// spec has no line for it (left to the builder); worded as Put on the
    /// Bench…'s failure.
    package static func failed(from: String, reason: String) -> String {
        "Couldn’t merge “\(from)”: \(reason)"
    }

    // MARK: Suggestion card, merge variant

    package static func cardLine(name: String, bench: String) -> String {
        "\(name) is on the “\(bench)” bench"
    }

    package static let mergeBenches = "Merge Benches…"
    package static let notNow = "Not Now"
}

/// What the merge confirmation shows and what Merge runs: bench `fromID`
/// merges into bench `intoID`. `askID` is the folder suggestion it was
/// offered from (answered once the merge is done), nil for Put on the
/// Bench…; `path` is the folder that was put on the bench.
package struct BenchMergeOffer: Equatable, Sendable, Identifiable {
    package let fromID: Int64
    package let fromName: String
    package let intoID: Int64
    package let intoName: String
    package let targets: Int
    package let folders: [String]
    package let path: String
    package let askID: Int64?
    /// B's owner-written settings that hold something and go with its row.
    package let dropped: [String]

    package var id: Int64 { fromID }

    package init(
        fromID: Int64,
        fromName: String,
        intoID: Int64,
        intoName: String,
        targets: Int,
        folders: [String],
        path: String,
        askID: Int64?,
        dropped: [String] = []
    ) {
        self.fromID = fromID
        self.fromName = fromName
        self.intoID = intoID
        self.intoName = intoName
        self.targets = targets
        self.folders = folders
        self.path = path
        self.askID = askID
        self.dropped = dropped
    }

    package var title: String { BenchMergePresentation.confirmTitle(from: fromName, into: intoName) }
    package var text: String {
        BenchMergePresentation.confirmText(from: fromName, into: intoName, targets: targets, folders: folders, dropped: dropped)
    }
}

/// A merge refused because the merged bench has live sessions.
package struct BenchMergeRefusal: Equatable, Sendable, Identifiable {
    package let fromName: String
    package let running: Int

    package var id: String { fromName }

    package init(fromName: String, running: Int) {
        self.fromName = fromName
        self.running = running
    }

    package var title: String { BenchMergePresentation.refusedTitle(from: fromName) }
    package var text: String { BenchMergePresentation.refusedText(from: fromName, running: running) }
}
