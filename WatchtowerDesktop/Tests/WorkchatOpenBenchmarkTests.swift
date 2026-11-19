import AppKit
import ChatUI
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Swift share of opening a Workchat pane (#2065 task 1): decode ->
/// `SessionFeedStore` apply -> `WorkchatFeedAdapter` -> an `NSHostingView`
/// layout of the feed, over a saved `session-feed --json` file named by
/// `WORKCHAT_BENCH_JSON`. Prints the `WorkchatOpenTrace` line for a first
/// open (cold store) and a reopen (the kept store). Skipped without the
/// variable. Lives in the app's test target, not Tests/Core: the feed view
/// is app code.
@MainActor
final class WorkchatOpenBenchmarkTests: XCTestCase {
    private struct FileRunner: CLIRunnerProtocol {
        let data: Data
        func run(args: [String]) async throws -> Data { data }
        func runModel(args: [String], origin: CLIOrigin, timeout: TimeInterval?, stdin: Data?) async throws -> Data { data }
    }

    private func paint(_ store: SessionFeedStore, trace: WorkchatOpenTrace) {
        let window = SessionFeedWindow()
        let total = store.entries.count
        let shown = Array(store.entries[window.range(total: total)])
        let feed = WorkchatFeed(entries: shown, markdown: SessionFeedMarkdownCache(), expandedEvents: [],
                                onOpenSubagent: { _ in }, onToggle: { _ in })
        let messages = feed.messages
        trace.mark(.adapter)
        let view = ChatUI.ChatFeedView(messages: messages, context: feed.context())
        let host = NSHostingView(rootView: view.frame(width: 760, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 700)
        host.layoutSubtreeIfNeeded()
        trace.mark(.paint)
    }

    func testOpenAndReopen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WORKCHAT_BENCH_JSON"] != nil, "benchmark only")
        let path = ProcessInfo.processInfo.environment["WORKCHAT_BENCH_JSON"] ?? ""
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let store = SessionFeedStore(sessionID: 1, runner: FileRunner(data: data))

        let first = try XCTUnwrap(store.openTrace)
        await store.refresh()
        XCTAssertFalse(store.entries.isEmpty, "bad fixture: no entries decoded")
        paint(store, trace: first)
        print("BENCH \(first.report ?? "no report") entries=\(store.entries.count)")

        store.beginOpenTrace(reopen: true)
        let reopen = try XCTUnwrap(store.openTrace)
        paint(store, trace: reopen)
        print("BENCH \(reopen.report ?? "no report") entries=\(store.entries.count)")
    }
}
