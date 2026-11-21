import Foundation

/// Spike S1 (agent connect spec §10 "Task 0 outcome"): whether the
/// customer's browser extension is connected, asked before a run's first
/// turn. The CLI's init event cannot tell, so a probe turn asks the browser
/// MCP server for its connected browsers: `[]` means words mode, a non-empty
/// list browser mode. Mid-run, a browser tool whose result says the
/// extension is gone moves the run to words (`browserLost`).
///
/// Unverified (no connected extension on the test Mac): the non-empty
/// result's shape. `mode(fromResult:)` reads it defensively — any non-empty
/// JSON array, or an object holding one, counts as connected, and so does a
/// summary cut short inside an array. Anything else is words.
package struct ConnectBrowserProbe: Sendable {
    /// The browser MCP server's name: a v2 `tool_start` shows its tools as
    /// `claude-in-chrome:<tool>`, the raw form is `mcp__claude-in-chrome__<tool>`.
    package static let browserServer = "claude-in-chrome"
    package static let listTool = "list_connected_browsers"
    /// The start of a browser tool's result once the extension is gone (it
    /// carries no error flag, so the text is what tells).
    package static let lostMarker = "Browser extension is not connected."
    /// The hidden turn after the browser was lost mid-run.
    package static let lostFollowUp = "The browser isn't available any more. Continue in words from the current step."
    package static let prompt = """
        Call the tool mcp__\(browserServer)__\(listTool) once, with no arguments. \
        Call no other tool and start no step of the playbook. \
        Then reply with the tool's raw result only.
        """
    package static let systemPrompt = "This turn only checks which browsers are connected."

    private let aiService: any AIServiceProtocol
    private let dbPath: String?

    package init(aiService: any AIServiceProtocol, dbPath: String? = nil) {
        self.aiService = aiService
        self.dbPath = dbPath
    }

    /// The run's mode on `harness`: words for a harness that cannot drive a
    /// browser (no probe turn), else the probe's answer. A probe that fails,
    /// is cancelled or calls no browser tool answers words; the run's first
    /// turn then reports a harness failure itself.
    package func mode(
        for harness: ConnectHarness,
        service: String,
        environment: [String: String]
    ) async -> ConnectAssistantMode {
        guard harness.capability == .browser else { return .words }
        let connectArgs = ChatSurfaceSpec.ToolAccess.connect(service: service, mode: .browser).connectArgs ?? []
        let (answers, answer) = AsyncStream<ConnectAssistantMode>.makeStream()
        let (aiService, dbPath, provider) = (aiService, dbPath, harness.id)
        return await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let events = aiService.stream(prompt: Self.prompt, systemPrompt: Self.systemPrompt, dbPath: dbPath,
                                              model: nil, provider: provider, connectArgs: connectArgs,
                                              extraEnvironment: environment)
                await Self.read(events, into: answer)
                answer.finish()
            }
            var mode = ConnectAssistantMode.words
            for await first in answers {
                mode = first
                break
            }
            // Answered, ended or cancelled: the reader is cancelled while it
            // waits on the stream, which ends the probe's process.
            group.cancelAll()
            return mode
        }
    }

    /// Yields the mode once the list tool's step ends; reads on until the
    /// stream ends or the reader is cancelled. A failed stream yields nothing.
    private static func read(
        _ events: AsyncThrowingStream<StreamEvent, Error>,
        into answer: AsyncStream<ConnectAssistantMode>.Continuation
    ) async {
        var listCalls: Set<String> = []
        do {
            for try await event in events {
                switch event {
                case .toolStart(let start) where isBrowserTool(start.name, named: listTool):
                    listCalls.insert(start.id)
                case .toolEnd(let end) where listCalls.contains(end.id):
                    answer.yield(end.ok ? mode(fromResult: end.summary) : .words)
                default:
                    continue
                }
            }
        } catch {
            return  // no answer: words
        }
    }

    /// Whether `name` (a v2 tool name, or the raw MCP name) is a tool of the
    /// browser server; with `named`, that one tool.
    package static func isBrowserTool(_ name: String, named tool: String? = nil) -> Bool {
        for prefix in ["\(browserServer):", "mcp__\(browserServer)__"] where name.hasPrefix(prefix) {
            guard let tool else { return true }
            return name.dropFirst(prefix.count) == tool
        }
        return false
    }

    /// Whether a browser tool's end says the extension is gone.
    package static func browserLost(_ end: ChatToolEnd) -> Bool {
        end.summary.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(lostMarker)
    }

    /// The mode a `list_connected_browsers` result asks for.
    package static func mode(fromResult result: String) -> ConnectAssistantMode {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasPrefix(lostMarker) else { return .words }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
            return holdsBrowsers(json) ? .browser : .words
        }
        // The step summary is cut at 300 characters: a long list is not JSON
        // any more, but it still opens an array with something in it.
        let opened = text.drop { $0 == "[" || $0 == "{" || $0.isWhitespace }
        return text.hasPrefix("[") && !opened.isEmpty && !opened.hasPrefix("]") ? .browser : .words
    }

    private static func holdsBrowsers(_ json: Any) -> Bool {
        if let list = json as? [Any] { return !list.isEmpty }
        if let object = json as? [String: Any] { return object.values.contains { ($0 as? [Any])?.isEmpty == false } }
        return false
    }
}
