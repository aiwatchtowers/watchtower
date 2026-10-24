import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

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

    /// `EmbeddedChatRows`' per-row look-ups (retry, answerQuestion,
    /// ownerReply) over a 100-message thread, every row once: the per-row
    /// map and scan it did before, then the one `ChatThreadIndex` per pass.
    func testEmbeddedRowLookups() {
        let items = Self.thread()
        let clock = ContinuousClock()
        let samples = (0..<15).map { _ in
            clock.measure {
                for item in items {
                    _ = items.last { $0.message.isAssistant }?.id == item.id
                    let rows = items.map(\.message)
                    if let index = rows.firstIndex(where: { $0.id == item.id }) {
                        _ = ChatQuestionThread.isAnswerable(at: index, in: rows, busy: false)
                    }
                    let rows2 = items.map(\.message)
                    if let index = rows2.firstIndex(where: { $0.id == item.id }) {
                        _ = ChatQuestionThread.ownerReply(after: index, in: rows2)
                    }
                }
            }
        }
        let indexed = (0..<15).map { _ in
            clock.measure {
                let thread = ChatThreadIndex(items.map(\.message))
                for item in items {
                    _ = thread.lastAssistantID == item.id
                    _ = thread.isAnswerable(item.id, busy: false)
                    _ = thread.ownerReply(after: item.id)
                }
            }
        }
        print("BENCH EmbeddedChatRows look-ups, 100 rows: per-row scans median \(median(samples)), " +
              "ChatThreadIndex median \(median(indexed))")
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

    /// The same rows in `ChatFeedView` (follow tracking, the content-frame
    /// preference every scroll tick), as the main and embedded chats show them.
    func testScrollLongThreadInChatFeed() throws {
        let items = Self.thread()
        let state = ChatAutoScrollPolicy.ThreadState(conversationID: 1, lastMessageID: items.last?.id,
                                                     scrollTarget: nil, liveMessageID: nil)
        try scrollBench("ChatFeedView", ChatFeedView(state: state, lastRowID: items.last?.id) { Self.rows(items) })
    }

    @ViewBuilder
    private static func rows(_ items: [ChatThreadItem]) -> some View {
        ForEach(items) { item in
            ChatMessageRow(item: item, isLast: item.id == items.last?.id, isEditing: false, actions: ChatRowActions())
                .equatable()
                .id(item.id)
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
        // The run loop turns between steps, as between the app's frames:
        // AppKit releases some views (TextKit 2 text views among them)
        // only there, so without it a case pays for the views of every
        // earlier one.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func step(to y: CGFloat) -> Duration {
            let time = clock.measure {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
            }
            RunLoop.main.run(mode: .default, before: Date())
            return time
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
