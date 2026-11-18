import Foundation
import GRDB
import WatchtowerCore

/// Merging benches (#2003, spec §6.13): a folder put on this bench from Put
/// on the Bench… or a suggestion card that is on another bench offers to
/// merge that bench into this one. Go does the merge (`workbench merge`);
/// the Desktop asks, shows the refusal, and afterwards FILES and the list.
extension WorkbenchesViewModel {
    /// Opens the merge confirmation for bench `fromID` into `projectID`,
    /// read from the database now (the names, its targets and folders).
    /// `askID`: the folder suggestion it came from, answered once the merge
    /// is done. Never a merge of a bench into itself (the folder is already
    /// here), nor of or into a bench no longer on the list (the failure line).
    func offerMerge(fromID: Int64, fromName: String, into projectID: Int64, path: String, askID: Int64? = nil) async {
        guard fromID != projectID else { return }
        do {
            let offer = try await dbPool.read { db -> BenchMergeOffer? in
                guard let into = try WorkbenchQueries.fetch(db, id: projectID),
                      let from = try WorkbenchQueries.fetch(db, id: fromID) else { return nil }
                let settings = try Row.fetchOne(
                    db, sql: "SELECT session_instructions, target_procedure, worktree_setup FROM projects WHERE id = ?",
                    arguments: [fromID]
                )
                return BenchMergeOffer(
                    fromID: fromID, fromName: from.name, intoID: projectID, intoName: into.name,
                    targets: try WorkbenchQueries.targetCount(db, workbenchID: fromID),
                    folders: try WorkbenchFolderQueries.benchFolders(db, workbenchID: fromID).live.map(\.name),
                    path: path, askID: askID,
                    dropped: BenchMergePresentation.droppedSettings(
                        sessionInstructions: settings?["session_instructions"],
                        targetProcedure: settings?["target_procedure"],
                        worktreeSetup: settings?["worktree_setup"]
                    )
                )
            }
            guard let offer else {
                putOnBenchErrors[projectID] = BenchMergePresentation.failed(from: fromName, reason: BenchMergePresentation.benchGone)
                return
            }
            mergeOffer = offer
        } catch {
            print("[WorkbenchMerge] reading workbench \(fromID) for the merge failed: \(error)")
            putOnBenchErrors[projectID] = BenchMergePresentation.failed(from: fromName, reason: error.localizedDescription)
        }
    }

    /// Cancel on the confirmation: nothing changes.
    func cancelMerge() {
        mergeOffer = nil
    }

    /// Merge on the confirmation, for the offer it presented (the alert
    /// clears `mergeOffer` as it closes). Refused while the other bench has
    /// live sessions (the refusal dialog with their count); after a merge the
    /// list drops the merged bench, FILES shows its folders (highlighting the
    /// one that was put on the bench), a folder whose reinstall failed shows
    /// the install icon with Retry (§7) and a failed later step a warning
    /// line — the data moved anyway.
    func confirmMerge(_ presented: BenchMergeOffer? = nil) async {
        guard let offer = presented ?? mergeOffer else { return }
        mergeOffer = nil
        guard let cli else {
            putOnBenchErrors[offer.intoID] = Self.cliMissingMessage
            return
        }
        guard !merging.contains(offer.intoID) else { return }
        merging.insert(offer.intoID)
        defer { merging.remove(offer.intoID) }
        putOnBenchErrors[offer.intoID] = nil
        mergeWarnings[offer.intoID] = nil
        let result: BenchMergeResult
        do {
            result = try await cli.merge(from: offer.fromID, into: offer.intoID)
        } catch {
            print("[WorkbenchMerge] workbench merge \(offer.fromID) into \(offer.intoID) failed: \(error)")
            putOnBenchErrors[offer.intoID] = BenchMergePresentation.failed(from: offer.fromName, reason: error.localizedDescription)
            return
        }
        guard result.ok else {
            if result.code == .sessionsRunning {
                mergeRefusal = BenchMergeRefusal(fromName: offer.fromName, running: max(result.running, 1))
            } else {
                putOnBenchErrors[offer.intoID] = BenchMergePresentation.failed(from: offer.fromName, reason: result.reason)
            }
            return
        }
        mergeWarnings[offer.intoID] = Self.mergeWarning(result, from: offer.fromName)
        await reload()
        await loadBenchFolders(projectID: offer.intoID)
        applyMergeReinstall(result, projectID: offer.intoID)
        let put = result.movedFolders.first { $0.path == offer.path }
        if let put {
            highlightedFolderRoot[offer.intoID] = put.id
            expandedFolderRoots[offer.intoID, default: []].insert(put.id)
        }
        if let askID = offer.askID {
            await asks.answerMergedSuggestion(askID: askID, name: put?.name ?? FolderSuggestionPresentation.folderName(offer.path))
        }
    }

    /// The warning line after a merge whose later steps failed; nil when none did.
    static func mergeWarning(_ result: BenchMergeResult, from: String) -> String? {
        var steps: [String] = []
        if !result.imagesError.isEmpty {
            print("[WorkbenchMerge] moving the target images failed: \(result.imagesError)")
            steps.append(BenchMergePresentation.imagesStep)
        }
        if !result.indexError.isEmpty {
            print("[WorkbenchMerge] updating search failed: \(result.indexError)")
            steps.append(BenchMergePresentation.searchStep)
        }
        return steps.isEmpty ? nil : BenchMergePresentation.partlyDone(from: from, steps: steps)
    }

    /// OK on the refusal dialog.
    func dismissMergeRefusal() {
        mergeRefusal = nil
    }

    /// The launch backstop for the Desktop's own launches (resume, Start
    /// fresh; spec §6.13, D37): a folder still installed for another (a
    /// merged) bench gets its own bench's install from Go first. Best effort:
    /// the launch goes on whatever it answers.
    func ensureInstallBeforeLaunch(_ row: TerminalSession) async {
        guard let projectID = row.projectID, row.kind.agent != nil, let cli,
              WorkbenchInstallCheck.needsReinstall(folder: row.folderPath, workbenchID: projectID) else { return }
        do {
            let result = try await cli.ensureInstall(sessionID: row.id)
            if !result.ok { print("[WorkbenchMerge] reinstalling for session \(row.id) failed: \(result.error)") }
        } catch {
            print("[WorkbenchMerge] workbench session ensure-install for session \(row.id) failed: \(error)")
        }
    }

    /// The moved folders' install flags as the merge's reinstall left them:
    /// a failed one shows the install icon with Retry.
    func applyMergeReinstall(_ result: BenchMergeResult, projectID: Int64) {
        let failed = Set(result.reinstall.failed.map(\.path))
        for folder in result.movedFolders {
            folderInstalled[projectID, default: [:]][folder.id] = failed.contains(folder.path) ? false : folder.installed
        }
    }
}
