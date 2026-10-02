import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Reproducible numbers for the large-text hot paths (#167): a streamed
/// answer's per-delta re-render and the parses that feed it. Each case
/// prints `BENCH …` lines (medians over interleaved samples, so a loaded
/// machine skews both sides alike); the assertions only pin the direction
/// of a measured win, never an absolute time. The print-only cases run
/// only with `WT_BENCH=1` in the environment.
@MainActor
final class TextRenderingBenchmarkTests: XCTestCase {
    /// Chat-shaped markdown of at least `chars` UTF-16 units: headings,
    /// paragraphs with inline styles and links, lists, code, tables, quotes.
    private static func markdown(chars: Int, seed: Int = 0) -> String {
        var out = ""
        var index = seed
        while out.utf16.count < chars {
            index += 1
            switch index % 6 {
            case 0: out += "## Section \(index)\n\n"
            case 1:
                out += "A paragraph with **bold \(index)**, a [link](https://example.com/\(index)), `code \(index)` "
                out += "and _emphasis_ running long enough to wrap across a couple of lines in a 700 point column.\n\n"
            case 2: out += "- item one \(index)\n- item two with **bold**\n- [ ] task \(index)\n\n"
            case 3: out += "```swift\nlet value\(index) = compute(\(index))\nif value\(index) > 0 { print(\"positive\") }\n```\n\n"
            case 4: out += "| col a | col b |\n|---|---|\n| \(index) | value \(index) |\n| x | y |\n\n"
            default: out += "> A quote \(index) with some text in it.\n\n"
            }
        }
        return out
    }

    private func mount<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return host
    }

    /// Streams `deltas` one-character deltas into a mounted view and returns
    /// each re-render's time (body + layout), as a published delta costs.
    private func streamSamples<V: View>(base: String, deltas: Int, _ make: (String) -> V) -> [Duration] {
        let host = mount(make(base))
        let clock = ContinuousClock()
        return (1...deltas).map { count in
            let text = base + String(repeating: "w", count: count)
            return clock.measure {
                host.rootView = make(text)
                host.layoutSubtreeIfNeeded()
                _ = host.fittingSize
            }
        }
    }

    private func median(_ samples: [Duration]) -> Duration {
        samples.sorted()[samples.count / 2]
    }

    /// Before: `MarkdownView` re-applied `.environment(\.openURL, …)` on every
    /// body pass. An `OpenURLAction` cannot be compared, so each streamed
    /// delta invalidated every `Text` of the message and re-laid it all out.
    func testStreamedDeltaNoLongerRelaysTheWholeMessage() {
        let text = Self.markdown(chars: 10_000, seed: 7)
        _ = mount(MarkdownView(text: Self.markdown(chars: 2_000, seed: 3))) // warm-up
        var before: [Duration] = []
        var after: [Duration] = []
        for _ in 0..<3 {
            before += streamSamples(base: text, deltas: 5) { LegacyMarkdownView(text: $0) }
            after += streamSamples(base: text, deltas: 5) { MarkdownView(text: $0) }
        }
        print("BENCH streamed delta, 10k-char message: before \(median(before)), after \(median(after))")
        XCTAssertLessThan(median(after), median(before))
    }

    /// The streamed row parses its text in `AssistantMessageBody.body` and
    /// again in `ChatViewModel.updateLiveArtifacts` per published delta; the
    /// second parse (and every finished row's re-parse on a scroll rebuild)
    /// is now a cache hit.
    func testRepeatArtifactParseIsACacheHit() {
        let text = Self.markdown(chars: 50_000, seed: 11)
        let clock = ContinuousClock()
        var first: ParsedMessage?
        var second: ParsedMessage?
        let cold = clock.measure { first = ArtifactParser.parse(text, final: false) }
        let warm = clock.measure { second = ArtifactParser.parse(text, final: false) }
        print("BENCH ArtifactParser.parse 50k chars: cold \(cold), repeat \(warm)")
        XCTAssertLessThan(warm, cold)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(ArtifactParser.parse(text, final: true), ArtifactParser.parse(text + "x", final: true),
                          "the key is the whole text, not a prefix")
    }

    /// What a published delta of a streamed answer costs end to end (both
    /// parses + body + layout) at growing lengths.
    func testStreamedAnswerFrameCostByLength() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WT_BENCH"] == "1", "benchmark only")
        _ = mount(MarkdownView(text: Self.markdown(chars: 2_000, seed: 3))) // warm-up
        for length in [2_000, 10_000, 30_000] {
            let base = Self.markdown(chars: length, seed: length)
            let samples = streamSamples(base: base, deltas: 6) { text in
                _ = ArtifactParser.parse(text, final: false) // updateLiveArtifacts
                return AssistantMessageBody(text: text, steps: [], isRunning: true)
            }
            print("BENCH streamed answer frame @\(length) chars: median \(median(samples))")
        }
    }

    /// A long conversation (200 answers of ~1.5k chars) in the thread's
    /// lazy stack: opening it, and a new message arriving at the bottom —
    /// finished rows must not be re-laid out when the thread grows.
    func testLongChatOpenAndAppend() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WT_BENCH"] == "1", "benchmark only")
        let answers = (0..<200).map { Self.markdown(chars: 1_500, seed: $0 * 13) }
        func thread(_ count: Int) -> some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<count, id: \.self) { index in
                        AssistantMessageBody(text: answers[index], steps: [], isRunning: false)
                    }
                }
            }
        }
        let clock = ContinuousClock()
        var host: NSHostingView<AnyView>?
        let open = clock.measure { host = mount(AnyView(thread(199))) }
        let append = clock.measure {
            host?.rootView = AnyView(thread(200))
            host?.layoutSubtreeIfNeeded()
        }
        print("BENCH 200-answer chat: open \(open), append one \(append)")
    }
}

/// `MarkdownView` as it was before #167, kept to measure against.
private struct LegacyMarkdownView: View {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownDocument.parse(text))
            .textSelection(.enabled)
            .environment(\.openURL, AllowedURLSchemes.openURLAction)
    }
}
