import Foundation
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// The Chats list's search (iPhone chat spec §6.2, mockup 1i). Typing filters the held list by title at once
/// (`ChatListModel`); after `debounce` without typing the query also goes to the hub as `chat_search`, whose record
/// fills "In messages". With no record `patience` after the send the line is "The Mac did not answer" with Retry.
/// Offline nothing is sent: titles only, with "Searching messages needs your Mac".
@MainActor
@Observable
final class ChatSearchModel {
    static let debounce: Duration = .milliseconds(300)
    static let patience: Duration = .seconds(30)
    /// The hub refuses a longer query (`chat_search`, 200 characters, counted as Go runes).
    static let maxQueryScalars = 200

    /// What the "In messages" part shows.
    enum Status: Equatable {
        /// No query, or the debounce still runs: titles only, no line.
        case idle
        /// The hub is away: titles only, with `ChatText.searchNeedsHub`.
        case offline
        /// Sent; the record is on its way.
        case searching
        /// The hub's hits for the query (maybe none).
        case results([ChatSearch.Hit])
        /// No record within `patience`, or the request could not be queued: `ChatText.noAnswer` with Retry.
        case noAnswer
    }

    private enum Phase: Equatable {
        case idle
        case debouncing
        case offline
        case sent(query: String, gaveUp: Bool)
    }

    /// The query as typed.
    private(set) var query = ""
    private var phase = Phase.idle
    /// Whether the hub can be asked now (`setOnline`).
    private(set) var online = true

    @ObservationIgnored private let sender: ChatSender
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var patienceTask: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatSearch")

    init(sender: ChatSender, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sender = sender
        self.sleep = sleep
    }

    /// The query the hub is asked: trimmed, cut at the hub's limit; "" asks nothing.
    static func wireQuery(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > maxQueryScalars else { return trimmed }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(maxQueryScalars))
        return String(scalars)
    }

    /// The owner typed: the debounce starts over.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        restart()
    }

    /// The screen keeps it current: a search held back while the hub was away goes once it is back.
    func setOnline(_ value: Bool) {
        guard value != online else { return }
        online = value
        if value, phase == .offline { retry() }
    }

    /// "The Mac did not answer" → Retry: asks again at once.
    func retry() {
        let wire = Self.wireQuery(query)
        guard !wire.isEmpty else { return }
        cancelTasks()
        ask(wire)
    }

    func status(in searches: [String: ChatSearch]) -> Status {
        switch phase {
        case .idle, .debouncing: return .idle
        case .offline: return .offline
        case let .sent(query, gaveUp):
            if let found = searches[query] { return .results(found.hits.filter { $0.messageID != nil }) }
            return gaveUp ? .noAnswer : .searching
        }
    }

    private func restart() {
        cancelTasks()
        let wire = Self.wireQuery(query)
        guard !wire.isEmpty else {
            phase = .idle
            return
        }
        phase = .debouncing
        let sleep = sleep
        debounceTask = Task { [weak self] in
            do { try await sleep(Self.debounce) } catch { return }
            guard !Task.isCancelled else { return }
            self?.ask(wire)
        }
    }

    private func ask(_ wire: String) {
        guard online else {
            phase = .offline
            return
        }
        phase = .sent(query: wire, gaveUp: false)
        let sender = sender
        let sleep = sleep
        patienceTask = Task { [weak self] in
            do {
                try await sender(ChatSearchParams(query: wire))
            } catch {
                Self.logger.warning("chat search not queued: \(String(describing: type(of: error)), privacy: .public)")
                self?.giveUp(wire)
                return
            }
            do { try await sleep(Self.patience) } catch { return }
            guard !Task.isCancelled else { return }
            self?.giveUp(wire)
        }
    }

    private func giveUp(_ wire: String) {
        guard phase == .sent(query: wire, gaveUp: false) else { return }
        phase = .sent(query: wire, gaveUp: true)
    }

    private func cancelTasks() {
        debounceTask?.cancel()
        debounceTask = nil
        patienceTask?.cancel()
        patienceTask = nil
    }
}

/// One "In messages" hit as its row draws it (mockup 1i): the chat's title, the snippet with the matched terms
/// bold, and the hit's age.
struct ChatHitRow: Identifiable, Equatable {
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    let id: String
    let route: ChatRoute
    let title: String
    let snippet: [Segment]
    let age: String

    init(_ hit: ChatSearch.Hit, now: Date, calendar: Calendar = .current) {
        id = "\(hit.conversationID)-\(hit.messageID ?? 0)"
        route = ChatRoute(id: hit.conversationID, messageID: hit.messageID)
        title = hit.title
        snippet = Self.segments(hit.snippet)
        age = ChatAge.label(hit.date, now: now, calendar: calendar)
    }

    /// The snippet split at the hub's match markers; an unclosed marker runs to the end.
    static func segments(_ snippet: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var inMatch = false
        func flush() {
            if !current.isEmpty { segments.append(Segment(text: current, isMatch: inMatch)) }
            current = ""
        }
        for character in snippet {
            switch String(character) {
            case ChatSearch.markStart:
                flush()
                inMatch = true
            case ChatSearch.markEnd:
                flush()
                inMatch = false
            default:
                current.append(character)
            }
        }
        flush()
        return segments
    }

    /// The snippet as one string with the matches bold.
    var attributedSnippet: AttributedString {
        snippet.reduce(into: AttributedString()) { result, segment in
            var part = AttributedString(segment.text)
            if segment.isMatch { part.inlinePresentationIntent = .stronglyEmphasized }
            result += part
        }
    }
}
