import Foundation

// MARK: - Overrides

/// Optional overrides applied when promoting a sub-item to a child target.
/// `nil` means "inherit the default" (parent fields, or sub-item text/due_date).
package struct PromoteSubItemOverrides {
    package var text: String?
    package var intent: String?
    package var level: String?
    package var priority: String?
    package var ownership: String?
    package var dueDate: String?       // "YYYY-MM-DDTHH:MM"
    package var periodStart: String?   // "YYYY-MM-DD"
    package var periodEnd: String?     // "YYYY-MM-DD"
    /// Tag list. `nil` inherits parent tags; an empty array clears them.
    package var tags: [String]?

    package init(
        text: String? = nil,
        intent: String? = nil,
        level: String? = nil,
        priority: String? = nil,
        ownership: String? = nil,
        dueDate: String? = nil,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        tags: [String]? = nil
    ) {
        self.text = text
        self.intent = intent
        self.level = level
        self.priority = priority
        self.ownership = ownership
        self.dueDate = dueDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.tags = tags
    }
}

// MARK: - Result

package struct PromoteSubItemResult {
    package var id: Int
    package var text: String
    package var level: String
    package var priority: String
    package var status: String
    package var dueDate: String
    package var periodStart: String
    package var periodEnd: String
    package var parentID: Int
    package var sourceType: String
    package var sourceID: String

    package init(
        id: Int,
        text: String,
        level: String,
        priority: String,
        status: String,
        dueDate: String,
        periodStart: String,
        periodEnd: String,
        parentID: Int,
        sourceType: String,
        sourceID: String
    ) {
        self.id = id
        self.text = text
        self.level = level
        self.priority = priority
        self.status = status
        self.dueDate = dueDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.parentID = parentID
        self.sourceType = sourceType
        self.sourceID = sourceID
    }
}

// MARK: - Service

/// Bridges the Desktop app to the `watchtower targets promote-subitem --json` subprocess.
/// Promotes the sub-item at `index` of `parentID` to a standalone child target with parent_id set.
package struct TargetPromoteSubItemService {
    package let runner: CLIRunnerProtocol

    package init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    package func promote(
        parentID: Int,
        index: Int,
        overrides: PromoteSubItemOverrides = PromoteSubItemOverrides()
    ) async throws -> PromoteSubItemResult {
        var args: [String] = [
            "targets", "promote-subitem",
            String(parentID), String(index),
            "--json",
        ]
        if let v = overrides.text {
            args.append(contentsOf: ["--text", v])
        }
        if let v = overrides.intent {
            args.append(contentsOf: ["--intent", v])
        }
        if let v = overrides.level {
            args.append(contentsOf: ["--level", v])
        }
        if let v = overrides.priority {
            args.append(contentsOf: ["--priority", v])
        }
        if let v = overrides.ownership {
            args.append(contentsOf: ["--ownership", v])
        }
        if let v = overrides.dueDate {
            args.append(contentsOf: ["--due", v])
        }
        if let v = overrides.periodStart {
            args.append(contentsOf: ["--period-start", v])
        }
        if let v = overrides.periodEnd {
            args.append(contentsOf: ["--period-end", v])
        }
        if let tags = overrides.tags {
            // Empty array → empty CLI value, which the Go side reads as "clear tags".
            args.append(contentsOf: ["--tags", tags.joined(separator: ",")])
        }

        let data = try await runner.run(args: args)
        let decoded = try JSONDecoder().decode(CLIPromoteResponse.self, from: data)

        return PromoteSubItemResult(
            id: decoded.id,
            text: decoded.text,
            level: decoded.level,
            priority: decoded.priority,
            status: decoded.status,
            dueDate: decoded.dueDate ?? "",
            periodStart: decoded.periodStart ?? "",
            periodEnd: decoded.periodEnd ?? "",
            parentID: decoded.parentID,
            sourceType: decoded.sourceType,
            sourceID: decoded.sourceID
        )
    }
}

// MARK: - Wire schema

/// Mirrors the JSON emitted by `watchtower targets promote-subitem --json`.
/// See `cmd/targets.go` `runTargetsPromoteSubItem` for the Go side.
/// String fields that the Go side may render as `""` are decoded as `String?`
/// to harden against future schema drift (e.g. `omitempty` on the Go side).
private struct CLIPromoteResponse: Decodable {
    let id: Int
    let text: String
    let level: String
    let priority: String
    let status: String
    let dueDate: String?
    let periodStart: String?
    let periodEnd: String?
    let parentID: Int
    let sourceType: String
    let sourceID: String

    enum CodingKeys: String, CodingKey {
        case id, text, level, priority, status
        case dueDate     = "due_date"
        case periodStart = "period_start"
        case periodEnd   = "period_end"
        case parentID    = "parent_id"
        case sourceType  = "source_type"
        case sourceID    = "source_id"
    }
}
