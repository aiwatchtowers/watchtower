import Foundation

/// A recipe's frontmatter as the edit form holds it (spec §2.2). `render`
/// writes only the keys Go's strict parser accepts (`internal/automations/
/// recipe.go`), every string a YAML double-quoted scalar; `splice` swaps the
/// leading `---…---` block of a recipe and keeps the rest byte-identical.
/// Comments inside the old frontmatter are not kept (v1 limit, said in the
/// form's footer). Go parses what `render` writes: the shared fixture
/// `internal/automations/testdata/recipes/swift_written.md` is pinned on both
/// sides (`RecipeFrontmatterTests`, `TestRecipe_ParsesSwiftWrittenFrontmatter`).
package struct RecipeFrontmatter: Equatable, Sendable {
    package enum Trigger: Equatable, Sendable {
        case schedule(String)
        case button(label: String, confirm: Bool)
        case event(type: String, where: [String: String])
        case manual
    }

    package var name: String
    package var trigger: Trigger
    /// `run_once` or `skip`.
    package var missed: String
    package var concurrency: Int
    package var permissions: [String]
    package var outputs: [String]
    package var budgetTokens: Int
    package var budgetMinutes: Int
    package var pauseTimeoutHours: Int

    package init(
        name: String,
        trigger: Trigger,
        missed: String = "run_once",
        concurrency: Int = 1,
        permissions: [String] = [],
        outputs: [String] = [],
        budgetTokens: Int = 50000,
        budgetMinutes: Int = 5,
        pauseTimeoutHours: Int = 72
    ) {
        self.name = name
        self.trigger = trigger
        self.missed = missed
        self.concurrency = concurrency
        self.permissions = permissions
        self.outputs = outputs
        self.budgetTokens = budgetTokens
        self.budgetMinutes = budgetMinutes
        self.pauseTimeoutHours = pauseTimeoutHours
    }

    /// The fields of a parsed recipe as `show --json` reports them.
    package init(detail: AutomationDetail) {
        self.init(
            name: detail.name,
            trigger: Self.trigger(kind: detail.triggerKind, specJSON: detail.triggerSpec),
            missed: detail.missedPolicy == "skip" ? "skip" : "run_once",
            concurrency: detail.concurrency,
            permissions: detail.permissions,
            outputs: detail.outputs,
            budgetTokens: detail.budgetTokens,
            budgetMinutes: detail.budgetMinutes,
            pauseTimeoutHours: detail.pauseTimeoutHours
        )
    }

    // MARK: - Trigger spec

    private struct Spec: Decodable {
        struct Button: Decodable {
            let label: String
            let confirm: Bool

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
                confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
            }

            private enum CodingKeys: String, CodingKey { case label, confirm }
        }

        struct Event: Decodable {
            let type: String?
            let `where`: [String: String]?
        }

        let schedule: String?
        let button: Button?
        let event: Event?
    }

    /// The `trigger_spec` column (`{"schedule":…}`, `{"button":{…}}`,
    /// `{"event":{…}}`, `{"manual":true}`) as a trigger; anything else is manual.
    package static func trigger(kind: String, specJSON: String) -> Trigger {
        let spec = try? JSONDecoder().decode(Spec.self, from: Data(specJSON.utf8))
        switch kind {
        case "schedule":
            return .schedule(spec?.schedule ?? "")
        case "button":
            return .button(label: spec?.button?.label ?? "", confirm: spec?.button?.confirm == true)
        case "event":
            return .event(type: spec?.event?.type ?? "", where: spec?.event?.where ?? [:])
        default:
            return .manual
        }
    }

    // MARK: - Render

    /// The frontmatter block, `---` lines included, each line `\n`-terminated.
    package static func render(_ f: Self) -> String {
        var lines = ["---", "name: \(quoted(f.name))", "trigger:"]
        switch f.trigger {
        case let .schedule(expr):
            lines.append("  schedule: \(quoted(expr))")
        case let .button(label, confirm):
            lines += ["  button:", "    label: \(quoted(label))", "    confirm: \(confirm)"]
        case let .event(type, filter):
            lines += ["  event:", "    type: \(quoted(type))"]
            if !filter.isEmpty {
                lines.append("    where:")
                for key in filter.keys.sorted() {
                    lines.append("      \(quoted(key)): \(quoted(filter[key] ?? ""))")
                }
            }
        case .manual:
            lines.append("  manual: true")
        }
        lines.append("missed: \(quoted(f.missed))")
        lines.append("concurrency: \(f.concurrency)")
        lines += list("permissions", f.permissions)
        lines += list("outputs", f.outputs)
        lines += ["budget:", "  tokens: \(f.budgetTokens)", "  minutes: \(f.budgetMinutes)"]
        lines.append("pause_timeout_hours: \(f.pauseTimeoutHours)")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func list(_ key: String, _ values: [String]) -> [String] {
        guard !values.isEmpty else { return ["\(key): []"] }
        return ["\(key):"] + values.map { "  - \(quoted($0))" }
    }

    /// A YAML double-quoted scalar: `\` and `"` escaped, control characters
    /// as escapes, everything else (`:`, `#`, `*`, non-ASCII) as is.
    package static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
                    || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0xFEFF {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Splice

    /// `recipeText` with its leading frontmatter block replaced by
    /// `render(f)`; the bytes after the closing `---` line are kept as they
    /// are. A text without a frontmatter block gets one in front.
    package static func splice(_ f: Self, into recipeText: String) -> String {
        guard let end = frontmatterEnd(recipeText) else { return render(f) + recipeText }
        return render(f) + recipeText[end...]
    }

    /// The leading frontmatter block of `recipeText`, `---` lines included,
    /// or nil when it has none.
    package static func block(in recipeText: String) -> Substring? {
        guard let end = frontmatterEnd(recipeText) else { return nil }
        return recipeText[..<end]
    }

    /// The index just past the line closing the frontmatter, following Go's
    /// `splitFrontmatter`: the first line is `---`, the next `---` line closes
    /// it (trailing blanks, a CR and a leading BOM tolerated). Lines are found
    /// in the UTF-8 view, so a CRLF ending is split like Go splits it.
    private static func frontmatterEnd(_ text: String) -> String.Index? {
        guard let offset = frontmatterEndOffset(Array(text.utf8)) else { return nil }
        return text.utf8.index(text.utf8.startIndex, offsetBy: offset)
    }

    private static func frontmatterEndOffset(_ bytes: [UInt8]) -> Int? {
        var start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var isFirstLine = true
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n"))
            let isFence = isFenceLine(bytes[start..<(newline ?? bytes.count)])
            if isFirstLine, !isFence { return nil }
            if !isFirstLine, isFence { return newline.map { $0 + 1 } ?? bytes.count }
            guard let newline else { return nil }
            start = newline + 1
            isFirstLine = false
        }
        return nil
    }

    private static func isFenceLine(_ line: ArraySlice<UInt8>) -> Bool {
        var end = line.endIndex
        while end > line.startIndex, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")]
            .contains(line[end - 1]) {
            end -= 1
        }
        return Array(line[line.startIndex..<end]) == Array("---".utf8)
    }
}
