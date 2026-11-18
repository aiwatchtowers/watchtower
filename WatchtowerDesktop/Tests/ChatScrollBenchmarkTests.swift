import AppKit
import ChatWire
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerChatText
@testable import ChatUI

/// Reproducible numbers for scrolling a long chat (automations tab polish,
/// spec §5): a 100-message thread whose answers are long markdown (tables,
/// lists, links, code) and carry tool steps, as the automation editor's
/// chat does. Print-only; runs only with `WT_BENCH=1` in the environment.
/// Each case prints `BENCH …` lines (medians over samples).
@MainActor
final class ChatScrollBenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WT_BENCH"] == "1", "benchmark only")
    }

    /// A long chat answer (~3k chars): headings, paragraphs with styles and
    /// links, a 4×6 table with links in cells, lists, code.
    private static func answer(_ seed: Int) -> String {
        var out = "## Draft \(seed)\n\n"
        out += "The recipe runs **every weekday at 9:00** and reads [the channel](https://example.com/c/\(seed)), "
        out += "then posts a short note with `output.inbox` and a [link to the run](https://example.com/r/\(seed)).\n\n"
        out += "| Step | Tool | Reads | Notes |\n|---|---|---|---|\n"
        for row in 0..<6 {
            out += "| \(row + 1) | `list_messages` | [#acme-\(row)](https://example.com/\(seed)/\(row)) | "
            out += "**\(row)** messages, _since_ yesterday |\n"
        }
        out += "\n- First, it collects the new messages \(seed)\n- Then it asks `llm()` for a summary with "
        out += "[a style](https://example.com/style)\n- [ ] Confirm the schedule\n- [x] Pick the channel\n\n"
        out += "```js\nconst msgs = tool(\"list_messages\", { channel: \"acme\", since: \"1d\" })\n"
        out += "output.inbox({ title: \"Daily \(seed)\", body: llm(msgs) })\n```\n\n"
        out += "1. Save the draft\n2. Confirm it\n3. Turn it on\n\n"
        out += "A closing paragraph with *emphasis*, ~~old text~~ and a link to [the guide](https://example.com/g) "
        out += "that runs long enough to wrap across two or three lines in a 700 point column, repeated: "
        out += String(repeating: "more words that wrap ", count: 12) + "\n"
        return out
    }

    private static func step(_ id: Int64, messageID: Int64) -> ChatTurnStep {
        let json = """
            {"id":\(id),"message_id":\(messageID),"seq":\(id),"tool_id":"t\(id)","name":"draft_automation",
             "args_json":"{\\"path\\":\\"daily.md\\"}","ok":1,"summary":"validated",
             "sources_json":"[{\\"kind\\":\\"automation\\",\\"title\\":\\"Daily\\",\\"url\\":null,\\"ref\\":\\"a:\(id)\\"}]",
             "started_at":1,"ended_at":2}
            """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ChatTurnStep.self, from: Data(json.utf8))
    }

    /// 50 owner turns + 50 answers, each answer with 3 tool steps.
    private static func thread() -> [ChatThreadItem] {
        (1...100).map { index -> ChatThreadItem in
            let id = Int64(index)
            let isUser = index % 2 == 1
            let message = ChatMessageRecord(id: id, conversationID: 1, role: isUser ? "user" : "assistant",
                                            text: isUser ? "Change the schedule to \(index):00 please" : answer(index),
                                            createdAt: Double(index), turnID: "t\((index + 1) / 2)")
            let steps = isUser ? [] : (0..<3).map { step(id * 10 + Int64($0), messageID: id) }
            return ChatThreadItem(message: message, steps: steps, siblingIndex: 1, siblingCount: 1)
        }
    }

    private func median(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count / 2] }
    private func p90(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count * 9 / 10] }

    /// Every inline run's `AttributedString` + link strip of the 50 answers:
    /// what the markdown rows' body passes pay when they all render once.
    func testInlineTextPass() {
        let answers = Self.thread().filter(\.message.isAssistant).map(\.message.text)
        var inlineRuns: [[MarkdownInline]] = []
        func collect(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case let .heading(_, inlines), let .paragraph(inlines): inlineRuns.append(inlines)
                case let .list(list): list.items.forEach { collect($0.blocks) }
                case let .quote(children): collect(children)
                case let .table(table): inlineRuns += table.header + table.rows.flatMap { $0 }
                case .code, .rule: break
                }
            }
        }
        answers.forEach { collect(MarkdownDocument.parse($0)) }
        let clock = ContinuousClock()
        let samples = (0..<15).map { _ in
            clock.measure { for inlines in inlineRuns { _ = MarkdownView.inlineText(inlines) } }
        }
        let unmemoised = (0..<15).map { _ in
            clock.measure {
                for inlines in inlineRuns {
                    _ = AllowedURLSchemes.strippingDisallowedLinks(MarkdownInlineRenderer.attributed(inlines))
                }
            }
        }
        print("BENCH inlineText, all \(inlineRuns.count) runs of 50 answers: unmemoised median " +
              "\(median(unmemoised)), inlineText median \(median(samples))")
    }

    /// `stepDisplays` (JSON-decodes every step's sources) for the 50 answers.
    func testStepDisplaysPass() {
        let items = Self.thread()
        let clock = ContinuousClock()
        let samples = (0..<15).map { _ in clock.measure { for item in items { _ = item.stepDisplays } } }
        print("BENCH stepDisplays, 100 rows: median \(median(samples))")
    }

    /// A streamed `message_upsert` over the last 60 messages (final review I4): the feed body pass's row build with
    /// every message derived again (no cache, as before) and with the feed's parts cache (only the streamed one).
    func testStreamedUpdateRowBuild() {
        let messages = Array(EmbeddedChatFeedAdapter.messages(rows: Self.thread(), live: nil).suffix(60))
        let last = messages[messages.count - 1]
        let cache = ChatMessagePartsCache()
        _ = ChatFeedLayout.rows(messages: messages, actions: [], cache: cache)
        let clock = ContinuousClock()
        var every: [Duration] = []
        var cached: [Duration] = []
        for tick in 0..<30 {
            var streamed = messages
            streamed[streamed.count - 1] = ChatFeed.Message(
                id: last.id, role: last.role, text: last.text + String(repeating: " more", count: tick + 1),
                status: "pending", createdAt: last.createdAt, steps: last.steps
            )
            every.append(clock.measure { _ = ChatFeedLayout.rows(messages: streamed, actions: []) })
            cached.append(clock.measure { _ = ChatFeedLayout.rows(messages: streamed, actions: [], cache: cache) })
        }
        print("BENCH streamed update row build, 60 messages: every message median \(median(every)), " +
              "parts cache median \(median(cached))")
    }

    /// The thread's rows in a `LazyVStack` (no feed), scrolled in a real
    /// window: the rows' own cost.
    func testScrollLongThread() throws {
        let items = Self.thread()
        try scrollBench("plain LazyVStack", ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) { Self.rows(items) }
                .padding(.horizontal, 20)
                .frame(maxWidth: 760)
        })
    }

    /// The same rows in ChatUI's feed with follow tracking (the content-frame
    /// preference every scroll tick), as the embedded chats and Workchat show them.
    func testScrollLongThreadInChatFeed() throws {
        let items = Self.thread()
        var context = ChatFeedContext()
        context.follow = ChatFeedFollow(conversationID: 1)
        try scrollBench("ChatFeedView", ChatUI.ChatFeedView(messages: EmbeddedChatFeedAdapter.messages(rows: items, live: nil),
                                                            context: context)
            .macChatStyle(hooks: ChatMacArtifactHooks()))
    }

    @ViewBuilder
    private static func rows(_ items: [ChatThreadItem]) -> some View {
        ForEach(items) { item in
            ChatUIShotRow.row(item).id(item.id)
        }
    }

    /// Scrolls `view` top → bottom → top in 300 pt steps, twice (the first
    /// pass warms up); each step's time is the layout pass that brings rows
    /// in (body + layout of the rows that scroll in).
    private func scrollBench<V: View>(_ label: String, _ view: V) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(Self.scrollView(in: host))
        let clock = ContinuousClock()
        // The run loop turns once per step, inside the timed part, as the
        // app's frame pays its autorelease drain, CA commit and view
        // teardown (TextKit 2 text views are released only there); the
        // settle first frees what an earlier case left.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func step(to y: CGFloat) -> Duration {
            clock.measure {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date())
            }
        }
        var down: [Duration] = []
        var back: [Duration] = []
        for pass in 0..<2 {
            var y: CGFloat = 0
            var steps: [Duration] = []
            var upSteps: [Duration] = []
            _ = step(to: 0)
            while y + 800 < (scroll.documentView?.frame.height ?? 0) {
                y += 300
                steps.append(step(to: y))
            }
            while y > 0 {
                y = max(0, y - 300)
                upSteps.append(step(to: y))
            }
            if pass == 1 { down = steps; back = upSteps }
        }
        let height = Int(scroll.documentView?.frame.height ?? 0)
        let total = (down + back).reduce(Duration.zero, +)
        print("BENCH scroll 100-message thread, \(label) (\(height) pt): down median \(median(down)) " +
              "p90 \(p90(down)) max \(down.max() ?? .zero); back median \(median(back)) p90 \(p90(back)) " +
              "max \(back.max() ?? .zero); steps \(down.count + back.count), total \(total)")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}
