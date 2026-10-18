import XCTest
@testable import WatchtowerCore

/// Board #590: a recording pane's notes saves run in order, and a queued
/// draft overtaken by a newer one of the same recording is skipped.
@MainActor
final class NotesSaveChainTests: XCTestCase {
    /// Runs one save the way `RecordingDetailView.saveNotes` does; `hold`
    /// keeps the write open until the test releases it, `started` reports
    /// that the write began.
    private func save(
        _ chain: NotesSaveChain,
        recording: Int64,
        draft: String,
        hold: Task<Void, Never>? = nil,
        started: (@MainActor () -> Void)? = nil,
        written: @escaping @MainActor (String) -> Void
    ) {
        let (previous, ticket) = chain.enqueue(recording)
        chain.last = Task {
            await previous?.value
            guard chain.isNewest(ticket, for: recording) else { return }
            started?()
            await hold?.value
            written(draft)
        }
    }

    func testOnlyTheNewestQueuedDraftIsWrittenAndInOrder() async {
        let chain = NotesSaveChain()
        var written: [String] = []
        let (gate, open) = AsyncStream<Void>.makeStream()
        let held = Task { for await _ in gate { return } }
        var firstStarted = false

        let markStarted: @MainActor () -> Void = { firstStarted = true }
        save(chain, recording: 7, draft: "first", hold: held, started: markStarted) { written.append($0) }
        // The first save is writing (held) before the next two queue.
        while !firstStarted { await Task.yield() }
        save(chain, recording: 7, draft: "second") { written.append($0) }
        save(chain, recording: 7, draft: "third") { written.append($0) }
        open.yield()
        await chain.last?.value

        XCTAssertEqual(written, ["first", "third"], "the overtaken queued draft is skipped, the newest lands last")
    }

    /// One pane shows several recordings in turn: another recording's save
    /// never makes this recording's draft skip.
    func testAnotherRecordingsSaveNeverSkipsThisOne() async {
        let chain = NotesSaveChain()
        var written: [String] = []

        save(chain, recording: 7, draft: "seven") { written.append($0) }
        save(chain, recording: 8, draft: "eight") { written.append($0) }
        await chain.last?.value

        XCTAssertEqual(written, ["seven", "eight"])
    }
}
