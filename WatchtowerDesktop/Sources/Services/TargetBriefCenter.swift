import Foundation
import WatchtowerCore

/// App-wide FIFO queue for the creation-time "brief the assistant" chat run
/// (spec §9.6). `CreateTargetSheet`'s Enter path creates the target row
/// mechanically, then hands the full composer text here — the center
/// constructs the target's `TargetChatViewModel`, sends the text through the
/// VM's normal send path (so persistence, streaming, and execute-mode
/// auto-apply all ride), and holds the VM while the run streams, so the run
/// survives the composer sheet being dismissed and any navigation away (the
/// "started → navigated away → came back" contract shared with
/// `TargetExtractCenter`).
/// Two VMs never race one conversation because the VM this center holds is the
/// same one the detail view gets: both go through `TargetAssistantCenter`'s
/// per-target container (wired in `AppState.makeChatVM`), so a brief started
/// from the composer keeps streaming into the very chat the owner opens.
///
/// Briefs run one at a time, oldest first (`MeetingRecorderCenter`'s
/// `jobs`/`activeJobID` precedent, owner decision 16): a second Enter-create
/// **queues behind** the first instead of superseding it, so an owner
/// instruction is never silently truncated mid-stream. A failed brief stays in
/// the queue, visible on its own target's banner until that target's failure
/// is dismissed, and never blocks the jobs behind it. The queue is uncapped —
/// each entry costs one owner keystroke to create, the same reasoning the
/// recorder queue uses. Known edge: `TargetAssistantCenter` keeps only a few
/// containers (LRU), so with more queued briefs than that, a queued target's
/// idle container can be evicted before its turn and the brief then streams
/// into a freshly built VM rather than the one a still-open chat is showing.
/// Queued brief text lives in memory only; quitting or crashing the app drops
/// queued briefs — accepted by the owner (2026-09-24).
@MainActor
@Observable
final class TargetBriefCenter {
    enum Phase: Equatable {
        case idle
        case queued(targetID: Int)
        case briefing(targetID: Int)
        case failed(targetID: Int, message: String)
    }

    /// One brief: waiting for the queue, streaming, or failed.
    struct BriefJob: Identifiable {
        enum Phase: Equatable {
            case queued
            case briefing
            case failed(String)

            var isFailed: Bool {
                if case .failed = self { return true }
                return false
            }
        }

        /// What the drain sends when this job reaches the front. Nil only for a
        /// job recorded by `markFailed` — a brief whose hand-off failed before
        /// there was anything to run — which is born `.failed` and therefore
        /// never reaches the drain.
        struct Request {
            let target: Target
            let text: String
        }

        let id = UUID()
        /// Carried by the job (not the center) so every phase, banner and VM
        /// hold stays attached to the target the brief was started for, even
        /// when a later brief is already streaming.
        let targetID: Int
        let request: Request?
        /// The VM driving this job — built when the job STARTS, not when it is
        /// enqueued (so a DB that opens in between still works), and held until
        /// the run finishes so the stream survives view teardown.
        var vm: TargetChatViewModel?
        var phase: Phase = .queued
    }

    /// The queue, oldest first. Read-only for the UI.
    private(set) var briefs: [BriefJob] = []
    /// The job the drain is currently streaming; nil when the queue is parked.
    private(set) var activeBriefID: BriefJob.ID?

    /// The running job's completion watcher. Internal (not private) so tests
    /// can await it (the `TargetExtractCenter.task` precedent).
    var task: Task<Void, Never>?

    /// Factory for the target chat VM — wired by AppState once the DB pool
    /// opens (centers are constructed before the DB). nil (no DB yet) fails
    /// the brief cleanly; the target row itself already exists (mechanical
    /// create, TGT-BRIEF-02).
    var makeChatVM: ((Target) -> TargetChatViewModel?)?

    /// Whether the target row still exists — wired by AppState next to
    /// `makeChatVM`. Asked when a queued brief falls due, so a target deleted
    /// while its brief waited never gets a conversation or a model call. nil
    /// (not wired) counts as "exists".
    var targetExists: ((Int) -> Bool)?

    /// Legacy single-slot projection: the running job, else the newest
    /// failure, else the head of the queue (the `MeetingRecorderCenter.phase`
    /// precedent). Every view site asks `phase(for:)` instead, since with a
    /// queue this scalar may well be describing a different target's job; it
    /// stays as the center's at-a-glance state and is what the suite asserts
    /// the whole queue's shape on.
    var phase: Phase {
        if let running = briefs.first(where: { $0.id == activeBriefID }) {
            return projected(running)
        }
        if let failed = briefs.last(where: { $0.phase.isFailed }) {
            return projected(failed)
        }
        if let head = briefs.first {
            return .queued(targetID: head.targetID)
        }
        return .idle
    }

    /// What this center is doing for ONE target: streaming beats a failure
    /// beats merely waiting. `.idle` means this target has nothing in the
    /// queue — another target's brief may well be streaming.
    func phase(for targetID: Int) -> Phase {
        let mine = briefs.filter { $0.targetID == targetID }
        if let running = mine.first(where: { $0.phase == .briefing }) {
            return projected(running)
        }
        if let failed = mine.last(where: { $0.phase.isFailed }) {
            return projected(failed)
        }
        if mine.contains(where: { $0.phase == .queued }) {
            return .queued(targetID: targetID)
        }
        return .idle
    }

    /// True while a brief for this target is queued or streaming — what the
    /// Assistant tab's working indicator shows, since from the owner's side a
    /// brief waiting its turn is still "being worked on".
    func isWorking(_ targetID: Int) -> Bool {
        switch phase(for: targetID) {
        case .queued, .briefing: return true
        case .idle, .failed: return false
        }
    }

    private func projected(_ job: BriefJob) -> Phase {
        switch job.phase {
        case .queued: return .queued(targetID: job.targetID)
        case .briefing: return .briefing(targetID: job.targetID)
        case let .failed(message): return .failed(targetID: job.targetID, message: message)
        }
    }

    /// Enqueue a brief run. A brief already streaming — for this target or any
    /// other — keeps streaming: nothing is cancelled here, and this job starts
    /// when the queue reaches it. An earlier target's `.failed` banner is left
    /// standing too; only `dismissFailure(targetID:)` clears one.
    func startBrief(target: Target, text: String) {
        briefs.append(BriefJob(targetID: target.id,
                               request: BriefJob.Request(target: target, text: text)))
        drain()
    }

    /// Start the next queued brief, if the slot is free. Everything up to the
    /// first suspension runs synchronously, so a caller that enqueues into an
    /// idle queue observes `.briefing` and can adopt the VM on the very next
    /// line (the composer's hand-off relies on that).
    private func drain() {
        guard activeBriefID == nil, let next = nextQueuedBrief() else { return }
        guard targetExists?(next.request.target.id) ?? true else {
            // Deleted while it waited: there is no screen left to show a
            // banner on, so the job just goes.
            briefs.removeAll { $0.id == next.id }
            drain()
            return
        }
        setPhase(.briefing, for: next.id)
        activeBriefID = next.id
        guard let chatVM = makeChatVM?(next.request.target) else {
            failToStart(next.id, message: "Database not available")
            return
        }
        // A queued target's chat is live on screen (the views land the owner
        // there), so by the time the brief is due the owner may have started
        // their own turn in it. `send()` would silently no-op on a streaming
        // VM, and the watcher would then mistake the OWNER's run for the
        // brief's — so a busy chat fails the brief visibly instead.
        guard !chatVM.isStreaming else {
            failToStart(next.id, message: "The chat was busy when this brief was due — re-ask here.")
            return
        }
        setVM(chatVM, for: next.id)
        guard send(next.request.text, on: chatVM) else {
            failToStart(next.id, message: "The brief could not be sent — re-ask here.")
            return
        }
        watch(next.id, chatVM: chatVM)
    }

    /// Send the brief through the VM's input field and report whether a
    /// stream actually started (`send()` flips `isStreaming` synchronously;
    /// still false means the send was a no-op, which must not pass for a
    /// finished brief).
    private func send(_ text: String, on chatVM: TargetChatViewModel) -> Bool {
        // The live VM may carry an error from an earlier OWNER turn; `finish`
        // reads `errorMessage` as this brief's outcome, so start it clean.
        chatVM.errorMessage = nil
        // An unsent owner draft sitting in the input is set aside and put
        // back once the send has consumed the brief.
        let draft = chatVM.inputText
        chatVM.inputText = text
        chatVM.send()
        chatVM.inputText = draft
        return chatVM.isStreaming
    }

    /// Poll until `isStreaming` clears, which observes the whole run (stream
    /// + execute-mode auto-apply), then settle the job and drain.
    private func watch(_ jobID: BriefJob.ID, chatVM: TargetChatViewModel) {
        task = Task { [weak self] in
            while chatVM.isStreaming, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // A cancelled watcher still settles its job and drains, so it can
            // never strand the queue — but it stops its stream first, or the
            // next brief would start while this one still runs unobserved.
            if Task.isCancelled { chatVM.cancelStream() }
            guard let self else { return }
            self.finish(jobID, vm: chatVM)
            self.drain()
        }
    }

    /// A job that could not start fails on its own target's banner and frees
    /// the slot for the rest of the queue.
    private func failToStart(_ jobID: BriefJob.ID, message: String) {
        activeBriefID = nil
        setVM(nil, for: jobID)
        setPhase(.failed(message), for: jobID)
        drain()
    }

    /// The oldest brief waiting to run. A `markFailed` record carries no
    /// request and is born `.failed`, so it is never picked up here.
    private func nextQueuedBrief() -> (id: BriefJob.ID, request: BriefJob.Request)? {
        for job in briefs where job.phase == .queued {
            if let request = job.request { return (job.id, request) }
        }
        return nil
    }

    private func finish(_ jobID: BriefJob.ID, vm: TargetChatViewModel) {
        activeBriefID = nil
        // Release the VM: an adopted one stays alive with its view; a detail
        // view opened later rebuilds from the persisted conversation, exactly
        // as it does today.
        setVM(nil, for: jobID)
        if let message = vm.errorMessage {
            // Not auto-cleared: the failure stays visible on THIS target's
            // banner until it is dismissed — a later brief for another target
            // never clears it.
            setPhase(.failed(message), for: jobID)
        } else {
            briefs.removeAll { $0.id == jobID }
        }
    }

    /// Record a brief that could not even start (e.g. the post-create fetch
    /// for the hand-off failed) so the target's detail view shows the same
    /// failure banner a failed run does. The row itself already exists.
    /// Per target: a brief streaming for any other target is untouched.
    func markFailed(targetID: Int, message: String) {
        briefs.append(BriefJob(targetID: targetID, request: nil, phase: .failed(message)))
    }

    /// Explicit dismissal of this target's failure banner (its close button).
    /// The owner recovers by re-asking in the target's chat (spec §7) — there
    /// is no Retry affordance.
    func dismissFailure(targetID: Int) {
        briefs.removeAll { $0.targetID == targetID && $0.phase.isFailed }
    }

    /// Forget every waiting or failed brief for a target that is being
    /// deleted. A brief already streaming is left to finish on its own.
    func drop(targetID: Int) {
        briefs.removeAll { $0.targetID == targetID && $0.id != activeBriefID }
    }

    /// The VM this center is holding for `targetID` — nil for any other target,
    /// for a brief still waiting its turn, or once the run has finished and the
    /// slot has been released. Views reach the same VM through
    /// `TargetAssistantCenter`; this accessor exists so the hold itself (the
    /// thing that makes the run survive navigation) is observable from outside,
    /// and it is what the center's tests assert on.
    func adoptVM(for targetID: Int) -> TargetChatViewModel? {
        briefs.first { $0.targetID == targetID && $0.vm != nil }?.vm
    }

    private func setPhase(_ phase: BriefJob.Phase, for jobID: BriefJob.ID) {
        guard let index = briefs.firstIndex(where: { $0.id == jobID }) else { return }
        briefs[index].phase = phase
    }

    private func setVM(_ vm: TargetChatViewModel?, for jobID: BriefJob.ID) {
        guard let index = briefs.firstIndex(where: { $0.id == jobID }) else { return }
        briefs[index].vm = vm
    }
}
