import Foundation

/// A failed overview step's error (Go `reviewai.RunError`, tech spec §3.6): the class,
/// the owner's one sentence, and the provider's own text, shown only behind a disclosure.
package struct ReviewRunError: Decodable, Equatable, Sendable {
    /// `timeout|provider|parse|cancelled|too_large|busy`.
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

/// One line of `workbench review overview … --json --stream` (tech spec §3.5).
package enum ReviewStreamEvent: Sendable {
    case map(ReviewMap)
    /// Another run holds the lock: `desktop|agent|cli`.
    case waiting(by: String)
    /// The run is alive. Every complete line the decoder does not recognise reads as a tick too.
    case tick
    case chapter(ReviewStreamChapter)
    case summary(ok: Bool, error: ReviewRunError?)
    /// The last line: the usual envelope (the overview, or the error with its class).
    case final(ReviewEnvelope)
}

/// A `chapter` line: the chapter's state, its description when described, and the
/// error of a failed one (its text and detail are in `state` too).
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

    /// One complete line → its event. Any line counts as life, so a line that is not a
    /// known, well-formed event is a tick: the stream's end is the envelope, and a chapter
    /// it never reported is settled from that.
    private func event(from line: Data) -> ReviewStreamEvent {
        guard let raw = try? decoder.decode(RawLine.self, from: line) else { return .tick }
        switch raw.event {
        case nil:
            guard raw.ok != nil, let env = try? decoder.decode(ReviewEnvelope.self, from: line) else { return .tick }
            return .final(env)
        case "map":
            return raw.map.map(ReviewStreamEvent.map) ?? .tick
        case "waiting":
            return .waiting(by: raw.by ?? "")
        case "chapter":
            guard let key = raw.key, let state = chapterState(raw) else { return .tick }
            return .chapter(ReviewStreamChapter(key: key, state: state, what: raw.what, risks: raw.risks ?? [], error: raw.error))
        case "summary":
            switch raw.state {
            case "ok": return .summary(ok: true, error: nil)
            case "failed": return .summary(ok: false, error: raw.error)
            default: return .tick
            }
        default:
            return .tick
        }
    }

    private func chapterState(_ raw: RawLine) -> ChapterRunState? {
        switch raw.state {
        case "ok": return .ok
        case "cached": return .cached
        case "not_started": return .notStarted
        case "failed":
            // Go always sends the error with a failed chapter.
            guard let error = raw.error else { return nil }
            return .failed(text: error.text, detail: error.detail)
        default: return nil
        }
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

        private enum CodingKeys: String, CodingKey { case event, ok, key, state, by, map, what, risks, error }

        // Field by field: a final envelope's `error` is a string, an event's an object;
        // a field of the other shape reads as absent.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = try? c.decodeIfPresent(String.self, forKey: .event)
            ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
            key = try? c.decodeIfPresent(String.self, forKey: .key)
            state = try? c.decodeIfPresent(String.self, forKey: .state)
            by = try? c.decodeIfPresent(String.self, forKey: .by)
            map = try? c.decodeIfPresent(ReviewMap.self, forKey: .map)
            what = try? c.decodeIfPresent(String.self, forKey: .what)
            risks = try? c.decodeIfPresent([ReviewOverview.Risk].self, forKey: .risks)
            error = try? c.decodeIfPresent(ReviewRunError.self, forKey: .error)
        }
    }
}
