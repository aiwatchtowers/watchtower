import Foundation

/// A failed overview step's error (Go `reviewai.RunError`, tech spec §3.6): the class,
/// the owner's one sentence, and the provider's own text, shown only behind a disclosure.
package struct ReviewRunError: Decodable, Equatable, Sendable {
    /// `timeout|provider|parse|cancelled|too_large|busy|missing_parts`.
    package let errorClass: String
    package let text: String
    package let detail: String?

    private enum CodingKeys: String, CodingKey {
        case errorClass = "class"
        case text, detail
    }

    package init(errorClass: String, text: String, detail: String? = nil) {
        self.errorClass = errorClass
        self.text = text
        self.detail = detail
    }
}

/// One chapter's state in the overview run (tech spec §5). The stream reports
/// `ok`, `cached`, `failed` and `notStarted`; `pending`, `running`, `queued` and
/// `waiting` are the Desktop's own states around it.
package enum ChapterRunState: Equatable, Sendable {
    case pending, running, queued, waiting, ok, cached
    /// `text` is the owner's sentence; `detail` the provider's text, kept apart.
    case failed(text: String, detail: String?)
    case notStarted
}

/// One line of `workbench review overview … --json --stream` (tech spec §3.5). Every
/// complete line counts as life; no recognised event is ever read as a plain tick.
package enum ReviewStreamEvent: Sendable {
    case map(ReviewMap)
    /// A `map` line whose map could not be read: the "Chapters could not be built" banner.
    case mapFailed
    /// Another run holds the lock: `desktop|agent|cli`.
    case waiting(by: String)
    /// The run is alive. A complete line with an unknown event name (or no JSON at all) reads as a tick too.
    case tick
    case chapter(ReviewStreamChapter)
    case summary(ok: Bool, error: ReviewRunError?)
    /// The last line: the usual envelope (the overview, or the error with its class).
    case final(ReviewEnvelope)
    /// A last line (it has `ok` and no `event`) that could not be read: the run's outcome is lost.
    case finalUnreadable
}

/// A `chapter` line: the chapter's state, its description when described (an empty one
/// reads as nil), and the error of a failed one (its text and detail are in `state` too).
package struct ReviewStreamChapter: Equatable, Sendable {
    package let key: String
    package let state: ChapterRunState
    package let what: String?
    package let risks: [ReviewOverview.Risk]
    package let error: ReviewRunError?
}

/// Turns the stream's bytes into events, one per complete line. A partial last line
/// is held until its newline arrives; one never completed (the process was killed)
/// is never decoded (Review Focus 5).
package struct ReviewOverviewStreamDecoder {
    private var buffer = Data()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    package init() {}

    package mutating func feed(_ data: Data) -> [ReviewStreamEvent] {
        buffer.append(data)
        var events: [ReviewStreamEvent] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            events.append(event(from: buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        return events
    }

    /// The owner's sentence for a failed chapter whose own error is missing or unreadable,
    /// a chapter in an unknown state, or a described chapter whose description could not be read.
    package static let chapterFailedText = "The overview of this chapter failed."
    /// The same for the summary.
    package static let summaryFailedText = "The overview of the summary failed."

    /// One complete line → its event. A recognised event that is malformed is reported as a
    /// failure, never as a tick; only an unknown event name (or a line that is not a JSON object) is.
    private func event(from line: Data) -> ReviewStreamEvent {
        guard let raw = try? decoder.decode(RawLine.self, from: line) else { return .tick }
        switch raw.event {
        case nil:
            guard raw.ok != nil else { return .tick }
            guard let env = try? decoder.decode(ReviewEnvelope.self, from: line) else { return .finalUnreadable }
            return .final(env)
        case "map":
            return raw.map.map(ReviewStreamEvent.map) ?? .mapFailed
        case "waiting":
            return .waiting(by: raw.by ?? "")
        case "chapter":
            // A chapter line without its key cannot be told apart; the envelope settles it.
            guard let key = raw.key else { return .tick }
            return .chapter(chapter(key: key, raw))
        case "summary":
            if raw.state == "ok" { return .summary(ok: true, error: nil) }
            return .summary(ok: false, error: raw.error ?? ReviewRunError(errorClass: "parse", text: Self.summaryFailedText))
        default:
            return .tick
        }
    }

    private func chapter(key: String, _ raw: RawLine) -> ReviewStreamChapter {
        if raw.state == "not_started" {
            return ReviewStreamChapter(key: key, state: .notStarted, what: nil, risks: [], error: nil)
        }
        if raw.state == "ok" || raw.state == "cached", raw.unreadable.isDisjoint(with: [.what, .risks]) {
            return ReviewStreamChapter(
                key: key,
                state: raw.state == "ok" ? .ok : .cached,
                what: raw.what.flatMap { $0.isEmpty ? nil : $0 },
                risks: raw.risks ?? [],
                error: nil
            )
        }
        // Failed (Go always sends its error, but a missing one still fails), an unknown
        // state, or a description that could not be read.
        let error = (raw.state == "failed" ? raw.error : nil)
            ?? ReviewRunError(errorClass: "parse", text: Self.chapterFailedText)
        return ReviewStreamChapter(key: key, state: .failed(text: error.text, detail: error.detail), what: nil, risks: [], error: error)
    }

    /// The union of every line's keys, all optional (an envelope line has `ok` and no `event`).
    private struct RawLine: Decodable {
        let event: String?
        let ok: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let key: String?
        let state: String?
        let by: String?
        let map: ReviewMap?
        let what: String?
        let risks: [ReviewOverview.Risk]?
        let error: ReviewRunError?
        /// The keys present with a value of the wrong shape.
        let unreadable: Set<CodingKeys>

        enum CodingKeys: String, CodingKey { case event, ok, key, state, by, map, what, risks, error }

        // Field by field: a final envelope's `error` is a string, an event's an object;
        // a field of the other shape reads as absent and is listed in `unreadable`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var bad: Set<CodingKeys> = []
            func field<T: Decodable>(_ key: CodingKeys) -> T? {
                do { return try c.decodeIfPresent(T.self, forKey: key) } catch {
                    bad.insert(key)
                    return nil
                }
            }
            event = field(.event)
            ok = field(.ok)
            key = field(.key)
            state = field(.state)
            by = field(.by)
            map = field(.map)
            what = field(.what)
            risks = field(.risks)
            error = field(.error)
            unreadable = bad
        }
    }
}
