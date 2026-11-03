import Foundation

// The block document of an automation's Inbox card (Inbox builder A, spec
// "The block document"): `{"v": 1, "blocks": [ … ]}` in Go's canonical form,
// stored in `automation_outputs.blocks_json`. Go validates and canonicalises
// it (`internal/automations/blocks`); this side only decodes canonical
// documents and never re-validates them. Foundation-only value types, so the
// Desktop's DesignKit and the phone decode the same JSON with one decoder.

/// The six tone names a script may give a row, a badge, a cell, a metric or
/// a person line. Colours come only from the name (`Tone.artifact`).
public enum ArtifactTone: String, CaseIterable, Equatable, Sendable {
    case neutral, info, success, warning, danger, accent
}

/// A row ref's record kind (spec "Row `ref`"); what a ref does is
/// sub-project B's, through `ArtifactRefHooks`.
public enum ArtifactRefKind: String, CaseIterable, Equatable, Sendable {
    case inboxItem = "inbox_item"
    case track, idea, reminder, action
}

/// A list row's record: `{kind, id}`, id > 0.
public struct ArtifactRef: Hashable, Sendable {
    public let kind: ArtifactRefKind
    public let id: Int64

    public init(kind: ArtifactRefKind, id: Int64) {
        self.kind = kind
        self.id = id
    }
}

/// The five things a button does. Stored as Go `db.InboxAction.Kind`, where
/// `open` is written `"link"`.
public enum ArtifactActionKind: String, CaseIterable, Hashable, Sendable {
    case open, chat, agent, reply, target

    /// The stored `kind` value.
    public var storedName: String { self == .open ? "link" : rawValue }
}

/// A `target` action's task: the press proposes `create_target` with these.
public struct ArtifactTargetAction: Equatable, Sendable {
    public let title: String
    /// Nil when the recipe gave none.
    public let intent: String?
    /// The parent target id; nil when the recipe gave none.
    public let parent: Int64?

    public init(title: String, intent: String? = nil, parent: Int64? = nil) {
        self.title = title
        self.intent = intent
        self.parent = parent
    }
}

/// One button: a card action or a block action, one grammar for both.
public struct ArtifactAction: Equatable, Sendable {
    /// An agent action's workbench: its id, or its name.
    public enum Workbench: Equatable, Sendable {
        case id(Int64)
        case name(String)
    }

    /// What the press does, with the fields of its kind.
    public enum Payload: Equatable, Sendable {
        /// The URL text (card URL rules, checked by Go and again at press time).
        case open(String)
        /// The first message for AI Chat.
        case chat(String)
        case agent(task: String, workbench: Workbench?)
        /// `dataJSON` is the action's `data`, re-serialised with sorted keys; nil when absent.
        case reply(value: String, dataJSON: String?)
        case target(ArtifactTargetAction)
    }

    public let label: String
    public let payload: Payload
    public let primary: Bool

    public init(label: String, payload: Payload, primary: Bool = false) {
        self.label = label
        self.payload = payload
        self.primary = primary
    }

    public var kind: ArtifactActionKind {
        switch payload {
        case .open: .open
        case .chat: .chat
        case .agent: .agent
        case .reply: .reply
        case .target: .target
        }
    }
}

/// A badge after a row's title.
public struct ArtifactBadge: Equatable, Sendable {
    public let text: String
    public let tone: ArtifactTone

    public init(text: String, tone: ArtifactTone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

/// One row of a `list` block.
public struct ArtifactListRow: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let badge: ArtifactBadge?
    /// The row's leading dot; nil draws no dot.
    public let tone: ArtifactTone?
    public let link: String?
    public let actions: [ArtifactAction]
    public let ref: ArtifactRef?

    public init(
        title: String,
        subtitle: String? = nil,
        badge: ArtifactBadge? = nil,
        tone: ArtifactTone? = nil,
        link: String? = nil,
        actions: [ArtifactAction] = [],
        ref: ArtifactRef? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.tone = tone
        self.link = link
        self.actions = actions
        self.ref = ref
    }
}

/// One column of a `table` block.
public struct ArtifactTableColumn: Equatable, Sendable {
    public enum Alignment: String, Equatable, Sendable {
        case leading, trailing
    }

    public let title: String
    public let align: Alignment

    public init(title: String, align: Alignment = .leading) {
        self.title = title
        self.align = align
    }
}

/// One cell of a `table` row: a plain string decodes to a cell with no tone or link.
public struct ArtifactTableCell: Equatable, Sendable {
    public let text: String
    public let tone: ArtifactTone?
    public let link: String?

    public init(text: String, tone: ArtifactTone? = nil, link: String? = nil) {
        self.text = text
        self.tone = tone
        self.link = link
    }
}

/// One figure of a `metrics` block; `value` is text the script formatted.
public struct ArtifactMetric: Equatable, Sendable {
    public let label: String
    public let value: String
    public let tone: ArtifactTone?
    public let hint: String?

    public init(label: String, value: String, tone: ArtifactTone? = nil, hint: String? = nil) {
        self.label = label
        self.value = value
        self.tone = tone
        self.hint = hint
    }
}

/// One line under a person's name.
public struct ArtifactPersonLine: Equatable, Sendable {
    public let text: String
    public let tone: ArtifactTone?

    public init(text: String, tone: ArtifactTone? = nil) {
        self.text = text
        self.tone = tone
    }
}

/// One block. Blocks are flat in v1: none contains another.
public enum ArtifactBlock: Equatable, Sendable {
    public struct List: Equatable, Sendable {
        public let title: String?
        public let rows: [ArtifactListRow]
        /// Shown when no row is drawn.
        public let empty: String

        public init(title: String? = nil, rows: [ArtifactListRow], empty: String = Self.defaultEmpty) {
            self.title = title
            self.rows = rows
            self.empty = empty
        }

        public static let defaultEmpty = "Nothing here"
    }

    public struct Table: Equatable, Sendable {
        public let title: String?
        public let columns: [ArtifactTableColumn]
        /// Each row has exactly `columns.count` cells (Go checks it).
        public let rows: [[ArtifactTableCell]]

        public init(title: String? = nil, columns: [ArtifactTableColumn], rows: [[ArtifactTableCell]]) {
            self.title = title
            self.columns = columns
            self.rows = rows
        }
    }

    public struct Person: Equatable, Sendable {
        public let name: String
        public let role: String?
        /// `"<account>:<user id>"` of the local `users` table; nil draws initials.
        public let slackUser: String?
        public let lines: [ArtifactPersonLine]
        public let link: String?

        public init(
            name: String,
            role: String? = nil,
            slackUser: String? = nil,
            lines: [ArtifactPersonLine] = [],
            link: String? = nil
        ) {
            self.name = name
            self.role = role
            self.slackUser = slackUser
            self.lines = lines
            self.link = link
        }
    }

    case heading(text: String, level: Int)
    case text(markdown: String)
    case list(List)
    case table(Table)
    case person(Person)
    case metrics([ArtifactMetric])
    case link(title: String, url: String, subtitle: String?)
    case actions([ArtifactAction])

    /// The block's actions in press order (a list's row by row).
    var actions: [ArtifactAction] {
        switch self {
        case let .list(list): list.rows.flatMap(\.actions)
        case let .actions(actions): actions
        default: []
        }
    }
}

/// What a stored `blocks_json` holds. Present-but-undecodable is never
/// folded into `none` (review rules, error handling).
public enum ArtifactDecodeResult: Equatable, Sendable {
    /// The empty string: the card has no blocks and keeps its markdown body.
    case none
    case document(ArtifactDocument)
    /// A `v` this app does not read: show the plain-text body and say so.
    case unsupported(version: Int)
    /// JSON that is not a v1 document: show the plain-text body and say so.
    case unreadable
}

/// A decoded block document.
public struct ArtifactDocument: Equatable, Sendable {
    /// The only version this app reads.
    public static let supportedVersion = 1

    public let version: Int
    public let blocks: [ArtifactBlock]

    public init(version: Int = Self.supportedVersion, blocks: [ArtifactBlock]) {
        self.version = version
        self.blocks = blocks
    }

    /// Decodes a stored `blocks_json`.
    public static func decode(_ json: String) -> ArtifactDecodeResult {
        if json.isEmpty { return .none }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
            as? [String: Any],
            let version = ArtifactJSON.integer(object["v"]) else { return .unreadable }
        guard version == supportedVersion else {
            return version > supportedVersion ? .unsupported(version: Int(version)) : .unreadable
        }
        guard let items = object["blocks"] as? [Any],
              let blocks = try? items.map(ArtifactJSON.block) else { return .unreadable }
        return .document(Self(version: Int(version), blocks: blocks))
    }

    /// A card's own `actions_json` (Go `db.InboxAction` array); nil when it
    /// is not an array of actions this app reads.
    public static func decodeActions(_ json: String) -> [ArtifactAction]? {
        guard let items = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] else { return nil }
        return try? items.map(ArtifactJSON.action)
    }

    /// Every press address of the card (spec "Press address"): the card's
    /// own actions first, then each block's in document order — a list's
    /// row by row, an `actions` block's in order. Go `blocks.FlattenActions`
    /// keeps the same order.
    public func flattenedActions(cardActions: [ArtifactAction]) -> [ArtifactAction] {
        cardActions + blocks.flatMap(\.actions)
    }

    /// Every list row's ref in document order (sub-project B's folder count).
    public var refs: [ArtifactRef] {
        blocks.flatMap { block -> [ArtifactRef] in
            guard case let .list(list) = block else { return [] }
            return list.rows.compactMap(\.ref)
        }
    }
}

/// The decoder's field readers: a missing required field throws, an absent
/// optional one (missing, `null` or `""`) is nil.
enum ArtifactJSON {
    struct Unreadable: Error {}

    static func block(_ value: Any) throws -> ArtifactBlock {
        let object = try dictionary(value)
        switch try string(object, "type") {
        case "heading":
            let level = try optionalInteger(object["level"]) ?? 1
            guard level == 1 || level == 2 else { throw Unreadable() }
            return .heading(text: try string(object, "text"), level: Int(level))
        case "text":
            return .text(markdown: try string(object, "markdown"))
        case "list":
            let rows = try array(object, "rows").map(row)
            return .list(.init(title: optionalString(object["title"]), rows: rows,
                               empty: optionalString(object["empty"]) ?? ArtifactBlock.List.defaultEmpty))
        case "table":
            return .table(try table(object))
        case "person":
            return .person(try person(object))
        case "metrics":
            return .metrics(try array(object, "items").map(metric))
        case "link":
            return .link(title: try string(object, "title"), url: try string(object, "url"),
                         subtitle: optionalString(object["subtitle"]))
        case "actions":
            return .actions(try array(object, "actions").map(action))
        default:
            throw Unreadable()
        }
    }

    static func action(_ value: Any) throws -> ArtifactAction {
        let object = try dictionary(value)
        let payload: ArtifactAction.Payload
        switch try string(object, "kind") {
        case "link":
            payload = .open(try string(object, "open"))
        case "chat":
            payload = .chat(try string(object, "chat"))
        case "agent":
            let agent = try dictionary(object["agent"] as Any)
            payload = .agent(task: try string(agent, "task"), workbench: workbench(agent["workbench"]))
        case "reply":
            guard let reply = object["reply"] as? String else { throw Unreadable() }
            payload = .reply(value: reply, dataJSON: try dataJSON(object["data"]))
        case "target":
            let target = try dictionary(object["target"] as Any)
            payload = .target(ArtifactTargetAction(title: try string(target, "title"),
                                                   intent: optionalString(target["intent"]),
                                                   parent: try optionalInteger(target["parent"])))
        default:
            throw Unreadable()
        }
        return ArtifactAction(label: try string(object, "label"), payload: payload,
                              primary: object["primary"] as? Bool ?? false)
    }

    private static func row(_ value: Any) throws -> ArtifactListRow {
        let object = try dictionary(value)
        return ArtifactListRow(
            title: try string(object, "title"),
            subtitle: optionalString(object["subtitle"]),
            badge: try optionalDictionary(object["badge"]).map {
                ArtifactBadge(text: try string($0, "text"), tone: try optionalTone($0["tone"]) ?? .neutral)
            },
            tone: try optionalTone(object["tone"]),
            link: optionalString(object["link"]),
            actions: try optionalArray(object["actions"]).map(action),
            ref: try optionalDictionary(object["ref"]).map(ref)
        )
    }

    private static func ref(_ object: [String: Any]) throws -> ArtifactRef {
        guard let kind = ArtifactRefKind(rawValue: try string(object, "kind")),
              let id = integer(object["id"]), id > 0 else { throw Unreadable() }
        return ArtifactRef(kind: kind, id: id)
    }

    private static func table(_ object: [String: Any]) throws -> ArtifactBlock.Table {
        let columns = try array(object, "columns").map { value -> ArtifactTableColumn in
            let column = try dictionary(value)
            let align = try optionalString(column["align"]).map {
                guard let align = ArtifactTableColumn.Alignment(rawValue: $0) else { throw Unreadable() }
                return align
            }
            return ArtifactTableColumn(title: try string(column, "title"), align: align ?? .leading)
        }
        guard !columns.isEmpty else { throw Unreadable() }
        let rows = try array(object, "rows").map { value -> [ArtifactTableCell] in
            guard let cells = value as? [Any], cells.count == columns.count else { throw Unreadable() }
            return try cells.map(cell)
        }
        return .init(title: optionalString(object["title"]), columns: columns, rows: rows)
    }

    private static func cell(_ value: Any) throws -> ArtifactTableCell {
        if let text = value as? String { return ArtifactTableCell(text: text) }
        let object = try dictionary(value)
        return ArtifactTableCell(text: try string(object, "text"), tone: try optionalTone(object["tone"]),
                                 link: optionalString(object["link"]))
    }

    private static func person(_ object: [String: Any]) throws -> ArtifactBlock.Person {
        let lines = try optionalArray(object["lines"]).map { value -> ArtifactPersonLine in
            if let text = value as? String { return ArtifactPersonLine(text: text) }
            let line = try dictionary(value)
            return ArtifactPersonLine(text: try string(line, "text"), tone: try optionalTone(line["tone"]))
        }
        let avatar = try optionalDictionary(object["avatar"])
        return .init(name: try string(object, "name"), role: optionalString(object["role"]),
                     slackUser: avatar.flatMap { optionalString($0["slack_user"]) }, lines: lines,
                     link: optionalString(object["link"]))
    }

    private static func metric(_ value: Any) throws -> ArtifactMetric {
        let object = try dictionary(value)
        return ArtifactMetric(label: try string(object, "label"), value: try string(object, "value"),
                              tone: try optionalTone(object["tone"]), hint: optionalString(object["hint"]))
    }

    // MARK: - Field readers

    private static func dictionary(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Unreadable() }
        return object
    }

    private static func optionalDictionary(_ value: Any?) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        return try dictionary(value)
    }

    /// A required, non-empty string.
    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let text = object[key] as? String, !text.isEmpty else { throw Unreadable() }
        return text
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func array(_ object: [String: Any], _ key: String) throws -> [Any] {
        guard let items = object[key] as? [Any] else { throw Unreadable() }
        return items
    }

    private static func optionalArray(_ value: Any?) throws -> [Any] {
        guard let value, !(value is NSNull) else { return [] }
        guard let items = value as? [Any] else { throw Unreadable() }
        return items
    }

    private static func optionalTone(_ value: Any?) throws -> ArtifactTone? {
        guard let name = optionalString(value) else { return nil }
        guard let tone = ArtifactTone(rawValue: name) else { throw Unreadable() }
        return tone
    }

    /// A JSON integer (never a bool or a fraction).
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number == NSNumber(value: number.int64Value) else { return nil }
        return number.int64Value
    }

    private static func optionalInteger(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = integer(value) else { throw Unreadable() }
        return number
    }

    /// A JSON integer is an id, a non-empty string a name; anything else none.
    private static func workbench(_ value: Any?) -> ArtifactAction.Workbench? {
        if let name = value as? String { return name.isEmpty ? nil : .name(name) }
        return integer(value).map { .id($0) }
    }

    private static func dataJSON(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value,
                                              options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        guard let text = String(bytes: data, encoding: .utf8) else { throw Unreadable() }
        return text
    }
}
