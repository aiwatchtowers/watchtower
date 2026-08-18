import Foundation
import WatchtowerCore

/// App-wide, single-slot registry for the creation-time "brief the secretary"
/// chat run (spec §9.6). `CreateTargetSheet`'s Enter path creates the target
/// row mechanically, then hands the full composer text here — the center
/// constructs the target's `TargetChatViewModel`, sends the text through the
/// VM's normal send path (so persistence, streaming, and execute-mode
/// auto-apply all ride), and holds the VM while the run streams, so the run
/// survives the composer sheet being dismissed and any navigation away (the
/// "начал → ушёл → вернулся" contract shared with `TargetExtractCenter`).
/// `TargetDetailView` adopts the held VM via `adoptVM(for:)` instead of
/// creating its own, so two VMs never race one conversation.
@MainActor
@Observable
final class TargetBriefCenter {
    enum Phase: Equatable {
        case idle
        case briefing(targetID: Int)
        case failed(targetID: Int, message: String)
    }

    private(set) var phase: Phase = .idle

    /// The in-flight completion watcher. Internal (not private) so tests can
    /// await it (the `TargetExtractCenter.task` precedent).
    var task: Task<Void, Never>?

    /// Factory for the target chat VM — wired by AppState once the DB pool
    /// opens (centers are constructed before the DB). nil (no DB yet) fails
    /// the brief cleanly; the target row itself already exists (mechanical
    /// create, TGT-BRIEF-02).
    var makeChatVM: ((Target) -> TargetChatViewModel?)?

    /// The VM driving the current run. Held until the run finishes so the
    /// stream survives view teardown; an adopted VM additionally stays alive
    /// with the adopting view's own strong reference.
    private var vm: TargetChatViewModel?
    private var vmTargetID: Int?

    func isBriefing(_ targetID: Int) -> Bool {
        phase == .briefing(targetID: targetID)
    }

    /// Start the brief run: build the VM, send `text` as the first owner
    /// message, and watch the stream to completion. Single-slot: a new brief
    /// supersedes a still-running one — the previous VM's stream is cancelled
    /// explicitly (so a superseded run can never keep streaming and auto-apply
    /// invisibly) before the reference is dropped; its persisted user message
    /// survives, so the owner re-asks in that target's chat — the spec §7
    /// failure contract. Starting a new brief also clears a lingering
    /// `.failed` phase.
    func startBrief(target: Target, text: String) {
        task?.cancel()
        vm?.cancelStream()
        guard let chatVM = makeChatVM?(target) else {
            vm = nil
            vmTargetID = nil
            phase = .failed(targetID: target.id, message: "Database not available")
            return
        }
        vm = chatVM
        vmTargetID = target.id
        phase = .briefing(targetID: target.id)
        chatVM.inputText = text
        chatVM.send()
        let targetID = target.id
        task = Task { [weak self] in
            // `send()` flips `isStreaming` synchronously, so polling until it
            // clears observes the whole run (stream + execute-mode auto-apply).
            while let vm = self?.vm, vm.isStreaming, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            if let message = self.vm?.errorMessage {
                // Not auto-cleared: the failure stays visible (the detail
                // view's banner) until dismissed or the next brief starts.
                self.phase = .failed(targetID: targetID, message: message)
            } else {
                self.phase = .idle
            }
            // Release the VM: an adopted one stays alive with its view; a
            // detail view opened later rebuilds from the persisted
            // conversation, exactly as it does today.
            self.vm = nil
            self.vmTargetID = nil
        }
    }

    /// Record a brief that could not even start (e.g. the post-create fetch
    /// for the hand-off failed) so the target's detail view shows the same
    /// failure banner a failed run does. The row itself already exists.
    func markFailed(targetID: Int, message: String) {
        phase = .failed(targetID: targetID, message: message)
    }

    /// Explicit dismissal of a `.failed` phase (the banner's close button).
    /// The owner recovers by re-asking in the target's chat.
    func dismissFailure() {
        if case .failed = phase {
            phase = .idle
        }
    }

    /// Hand the held VM to the detail view for `targetID` (nil for any other
    /// target, or when no run is held). The center keeps its own reference
    /// until the run finishes, so the run still survives the adopting view.
    func adoptVM(for targetID: Int) -> TargetChatViewModel? {
        guard vmTargetID == targetID else { return nil }
        return vm
    }
}
