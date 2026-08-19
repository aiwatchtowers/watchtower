import Foundation

// MARK: - Assistant Skills catalog (Swift side of the dual-path)
//
// Reads `<workspace>/skills/*.md` — the assistant-skill files the Go side
// deploys and parses in `internal/skills/`. This is a deliberate dual-path
// (the `saveNotes` precedent): the file format is the single source of truth
// shared by both sides, so the parsing semantics here MUST stay equivalent to
// the Go parser — filename stem is the identity (`^[a-z0-9][a-z0-9-]*$`),
// frontmatter between `---` lines carries `description` (required non-empty)
// and `enabled` (optional, default true). Invalid files are skipped, never
// fatal; unknown frontmatter keys are ignored — including the `persona` key
// files from the two-persona era still carry. Equivalence is pinned by the
// SHARED fixtures in
// `internal/skills/testdata`, which `internal/skills.TestListFixtures` and
// `SkillsCatalogTests.testSharedGoFixturesGetTheSameVerdict` both read.
//
// Go feeds the frontmatter to `gopkg.in/yaml.v3`; this is a hand parser, so
// every shape yaml.v3 refuses has to be refused here by hand. What it accepts
// is deliberately a strict SUBSET of YAML: one `key: value` mapping entry per
// line, starting at column zero, with plain, single-quoted or double-quoted
// scalars and `#` comments. Everything else is refused.
//
// So the two sides can still disagree, but only in the direction where Swift
// refuses a file Go accepts: the prompt then never advertises the skill, which
// costs the owner a listing. The reverse — Swift listing a skill `load_skill`
// cannot read, or listing it with a description Go reads differently — is the
// failure this subset exists to prevent, and no shape is currently known to
// produce it.
//
// The refused-but-legal shapes, each verified against yaml.v3 (see the
// fixtures in `internal/skills/testdata` and the probes recorded in the
// review):
//   - any indented line, and therefore nested mappings, sequences and folded
//     continuations under a key, plus uniformly indented frontmatter;
//   - a scalar continued onto the next line (`"a\` + newline + `b"`);
//   - `\xNN`, `\uNNNN` and `\UNNNNNNNN` escapes in a double-quoted scalar;
//   - a quoted key whose own text contains a `: ` separator (`"a: b": c`);
//   - a plain key ending in a colon (`a:: c`, whose key yaml.v3 reads as `a:`);
//   - a key that is a bare block-entry indicator (`-: c` and `?: c`, whose keys
//     yaml.v3 reads as `-` and `?`);
//   - an anchor or a tag on a scalar, in a value (`description: &a hey`, which
//     yaml.v3 hands Go as just `hey` — a listing whose text does not match the
//     file) or on a key (`&a description: x` and `!t note: x`, likewise).

/// One parsed skill file's listing-level data (the body stays on disk — it is
/// served by the `load_skill` MCP tool, never inlined into the system prompt).
package struct SkillSummary: Sendable, Equatable {
    package let name: String
    package let description: String
    package let enabled: Bool
    /// True when the file carries the `x-watchtower-shipped` frontmatter
    /// marker `internal/skills` stamps on the pack it deploys — the origin
    /// badge the Settings card renders, read here so no caller needs a second
    /// pass over the same file.
    package let shipped: Bool

    package init(
        name: String,
        description: String,
        enabled: Bool,
        shipped: Bool = false
    ) {
        self.name = name
        self.description = description
        self.enabled = enabled
        self.shipped = shipped
    }
}

// MARK: - Frontmatter scalars

/// The YAML-scalar semantics the two parsers must agree on, in one place: the
/// catalog below reads frontmatter with it, and the Settings editor
/// (`SkillFileEditor`) reads the `enabled` key with it, so a value one of them
/// honours can never be a value the other silently rewrites.
///
/// The rules are yaml.v3's, pinned empirically against `internal/skills.Parse`
/// rather than guessed from the YAML spec.
package enum SkillFrontmatter {
    /// A frontmatter value as YAML reads it: the scalar's text, plus whether
    /// it was written quoted. Quoting is not cosmetic — it decides the node's
    /// type, which is why `enabled: false` is a bool and `enabled: "false"` is
    /// a string yaml.v3 refuses to unmarshal into one.
    package struct Value: Equatable, Sendable {
        package let text: String
        package let quoted: Bool
    }

    /// How yaml.v3 reads a value into the `*bool` `enabled` field.
    package enum BoolValue: Equatable, Sendable {
        case on
        case off
        /// An explicit YAML null (`~`, `null`) or an empty value: the key is
        /// present but carries no bool, so the format's default applies.
        case unset
        /// Anything yaml.v3 would refuse to unmarshal into a bool — a quoted
        /// `"true"`, a number, an unknown word. Go rejects the whole file.
        case invalid
    }

    /// Read the value half of a `key: value` frontmatter line. Returns nil for
    /// every shape yaml.v3 refuses, or reads as something other than its own
    /// literal text: an unterminated quoted scalar, junk after a closing quote,
    /// an unknown escape, a plain scalar carrying an unquoted `key: value`
    /// separator, or a plain scalar opening with a YAML indicator (a flow
    /// collection, an anchor, a tag, an alias, a block scalar) — those either
    /// break the document or make yaml.v3 hand Go a DIFFERENT string than the
    /// bytes on the line, which is worse than refusing them.
    package static func value(_ raw: some StringProtocol) -> Value? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return Value(text: "", quoted: false) }
        if first == "'" || first == "\"" {
            return quoted(trimmed, quote: first)
        }
        return plain(trimmed)
    }

    /// Read the key half of a `key: value` frontmatter line, unquoted. Returns
    /// nil for every shape yaml.v3 refuses there — a sequence entry, a flow
    /// collection, an alias, an empty key, a broken or trailing-junk quoted
    /// scalar, a plain key carrying an inline comment — and for the anchored
    /// and tagged keys yaml.v3 accepts but reads as a different key than the
    /// bytes on the line.
    ///
    /// A key is a scalar with the same rules as a value, so it runs through the
    /// same machinery: the ONE difference is that nothing at all may follow a
    /// quoted key, not even a comment (`"a" junk: c` and `a #x: c` are both
    /// errors on the Go side). Unquoting here is what makes `"description": x`
    /// reach the description field, exactly as it does in Go, and what makes a
    /// plain key and its quoted spelling collide as the duplicate they are.
    package static func key(_ raw: some StringProtocol) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if first == "'" || first == "\"" {
            return quoted(trimmed, quote: first, allowTrailingComment: false)?.text
        }
        // `value.text == trimmed` is the comment check: a plain key that lost
        // characters to `strippingComment` is a key yaml.v3 never sees.
        guard let value = plain(trimmed), value.text == trimmed else { return nil }
        return value.text
    }

    /// `value` plus the bool reading, for callers holding the raw line.
    package static func bool(_ raw: some StringProtocol) -> BoolValue {
        guard let value = value(raw) else { return .invalid }
        return bool(value)
    }

    package static func bool(_ value: Value) -> BoolValue {
        // The YAML-1.1 words are accepted even when quoted, because yaml.v3
        // applies them while decoding a STRING into a typed bool; the
        // core-schema words are not, so `enabled: "false"` stays a string and
        // is refused. Both lists are closed and case-sensitive — `yEs` is a
        // plain string and rejected.
        if yaml11True.contains(value.text) { return .on }
        if yaml11False.contains(value.text) { return .off }
        if value.quoted { return .invalid }
        if coreTrue.contains(value.text) { return .on }
        if coreFalse.contains(value.text) { return .off }
        if nullTokens.contains(value.text) { return .unset }
        return .invalid
    }

    private static let yaml11True: Set<String> = ["y", "Y", "yes", "Yes", "YES", "on", "On", "ON"]
    private static let yaml11False: Set<String> = ["n", "N", "no", "No", "NO", "off", "Off", "OFF"]
    private static let coreTrue: Set<String> = ["true", "True", "TRUE"]
    private static let coreFalse: Set<String> = ["false", "False", "FALSE"]
    private static let nullTokens: Set<String> = ["", "~", "null", "Null", "NULL"]

    /// A plain (unquoted) scalar, or nil when yaml.v3 would read it as
    /// structure rather than as text. See `value`'s doc for why the indicator
    /// cases are refused rather than taken literally.
    private static func plain(_ trimmed: String) -> Value? {
        let text = strippingComment(trimmed)
        guard let first = text.first else { return Value(text: "", quoted: false) }
        guard !refusedIndicators.contains(first) else { return nil }
        // `-` and `?` open a block entry only when the value is the bare
        // indicator or the indicator plus whitespace; `-5 items` and `?why` are
        // ordinary text to yaml.v3, and stay ordinary text here.
        if blockEntryIndicators.contains(first) {
            let next = text.dropFirst().first
            if next == nil || next == " " || next == "\t" { return nil }
        }
        // An unquoted `: ` (or a trailing `:`) is a mapping separator, not
        // text — "Use when: the owner asks" is the realistic way an owner
        // writes a description that yaml.v3 then refuses outright.
        guard !text.contains(": "), !text.contains(":\t"), !text.hasSuffix(":") else { return nil }
        return Value(text: text, quoted: false)
    }

    /// Leading characters that make a plain scalar something other than its own
    /// text: flow collections, an alias, a tag, an anchor, a block scalar, a
    /// directive, and the two YAML reserves. Pinned by probe against yaml.v3 —
    /// `!x y` and `&x y` both parse to just `y`, the rest are hard errors.
    private static let refusedIndicators: Set<Character> = [
        "[", "]", "{", "}", ",", "*", "!", "&", "|", ">", "%", "@", "`"
    ]
    private static let blockEntryIndicators: Set<Character> = ["-", "?"]

    /// The escapes yaml.v3 accepts inside a double-quoted scalar, mapped to the
    /// same characters it produces. The set is the whole single-character table
    /// yaml.v3 has, swept character by character against it — including `\'`
    /// and a backslash before a literal tab, and NOT `\/`, which is legal JSON
    /// and not legal YAML. Anything outside it — an unknown letter, or the
    /// numeric `\xNN`/`\uNNNN`/`\UNNNNNNNN` forms this parser does not decode —
    /// is refused rather than passed through as a literal, so the description
    /// text can never differ between the two sides.
    private static let doubleQuoteEscapes: [Character: Character] = [
        "0": "\0", "a": "\u{07}", "b": "\u{08}", "e": "\u{1B}", "f": "\u{0C}",
        "n": "\n", "r": "\r", "t": "\t", "v": "\u{0B}", "L": "\u{2028}",
        "N": "\u{85}", "P": "\u{2029}", "_": "\u{A0}", " ": " ", "\"": "\"",
        "\\": "\\", "'": "'", "\t": "\t"
    ]

    /// Unwrap a quoted scalar: `''` is an escaped quote inside single quotes, a
    /// backslash escapes the next character inside double ones. A comment may
    /// follow the closing quote of a value; nothing at all may follow the
    /// closing quote of a key.
    private static func quoted(
        _ trimmed: String,
        quote: Character,
        allowTrailingComment: Bool = true
    ) -> Value? {
        var text = ""
        var index = trimmed.index(after: trimmed.startIndex)
        var closed = false
        while index < trimmed.endIndex {
            let char = trimmed[index]
            index = trimmed.index(after: index)
            if quote == "\"", char == "\\" {
                guard index < trimmed.endIndex,
                      let mapped = doubleQuoteEscapes[trimmed[index]] else { return nil }
                index = trimmed.index(after: index)
                text.append(mapped)
                continue
            }
            if char == quote {
                if quote == "'", index < trimmed.endIndex, trimmed[index] == "'" {
                    text.append("'")
                    index = trimmed.index(after: index)
                    continue
                }
                closed = true
                break
            }
            text.append(char)
        }
        guard closed else { return nil }
        let rest = trimmed[index...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || (allowTrailingComment && rest.hasPrefix("#")) else { return nil }
        return Value(text: text, quoted: true)
    }

    /// Cut an inline comment off a plain scalar. `#` only opens one at the
    /// start of the value or after whitespace — `a#b` is the literal `a#b`.
    private static func strippingComment(_ trimmed: String) -> String {
        var index = trimmed.startIndex
        var afterSpace = true
        while index < trimmed.endIndex {
            let char = trimmed[index]
            if char == "#", afterSpace {
                return String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
            }
            afterSpace = char == " " || char == "\t"
            index = trimmed.index(after: index)
        }
        return trimmed
    }
}

package enum SkillsCatalog {
    /// Chat `context_type`s whose prompts list skills, mirroring the assistant
    /// contract in `docs/review/review-rules.md` ("The assistant & chat
    /// contracts"). Setup/onboarding chats are deliberately absent.
    ///
    /// Swift-side only, with no Go twin: every chat prompt is built in Swift.
    /// A chat surface joins the set by adding its `context_type` here — see
    /// `promptBlock(contextType:dir:)`, which every chat VM goes through.
    package static let chatContextTypes: Set<String> = [
        "situation", "meeting", "target", "track", "idea"
    ]

    /// The active workspace's skills directory
    /// (`<activeWorkspaceDir>/skills`), or nil when no workspace is active —
    /// the `Constants.memoryVaultDir()` precedent.
    package nonisolated static func defaultDir() -> String? {
        guard let workspaceDir = Constants.activeWorkspaceDir() else { return nil }
        return "\(workspaceDir)/skills"
    }

    /// Skill filename-stem identity: lowercase alphanumerics and hyphens, not
    /// starting with a hyphen. It doubles as the path-traversal guard on the
    /// Go side, so it must never admit a separator, a dot, or an empty string.
    /// (Also the Settings editor's name validator, hence `package` rather than
    /// `private` — the create sheet must reject exactly what the catalog would
    /// silently skip.)
    package nonisolated static func isValidSkillName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let lowerDigit = (first >= "a" && first <= "z") || (first >= "0" && first <= "9")
        guard lowerDigit else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
        }
    }

    /// Parse every valid skill file in `dir`, sorted by name. A missing or
    /// unreadable directory is an empty list; an invalid file is skipped
    /// silently (one bad file must not break the catalog).
    package nonisolated static func list(dir: String?) -> [SkillSummary] {
        guard let dir, !dir.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return [] }
        var skills: [SkillSummary] = []
        for entry in entries where entry.hasSuffix(".md") {
            let name = String(entry.dropLast(3))
            guard let content = try? String(contentsOfFile: "\(dir)/\(entry)", encoding: .utf8),
                  let skill = parse(name: name, content: content)
            else { continue }
            skills.append(skill)
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// The frontmatter key `internal/skills` stamps on every file it ships.
    /// An ordinary unknown key to both parsers; only the origin badge reads it.
    package static let shippedMarkerKey = "x-watchtower-shipped"

    /// Parse one skill file's frontmatter. Strict on what matters, lenient
    /// elsewhere: nil (skip) on an illegal name, a missing/unterminated
    /// frontmatter block, a line yaml.v3 would refuse, a `description` that is
    /// empty once unquoted and trimmed, or an `enabled` value that is not a
    /// YAML bool; unknown keys are ignored (the legacy `persona` key included)
    /// and `enabled` defaults to true when absent.
    package nonisolated static func parse(name: String, content: String) -> SkillSummary? {
        guard isValidSkillName(name), let fields = frontmatterFields(content) else { return nil }

        let description = (fields["description"]?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }

        var enabled = true
        if let value = fields["enabled"] {
            switch SkillFrontmatter.bool(value) {
            case .on, .unset: enabled = true
            case .off: enabled = false
            case .invalid: return nil
            }
        }

        let shipped = !(fields[shippedMarkerKey]?.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return SkillSummary(
            name: name, description: description,
            enabled: enabled, shipped: shipped
        )
    }

    /// The frontmatter block's `key: value` pairs, or nil when the file has no
    /// terminated block or carries a line the Go parser would choke on: a
    /// non-`key: value` line, a broken scalar, or a repeated key (yaml.v3
    /// refuses a duplicate mapping key even on a field it does not read).
    nonisolated private static func frontmatterFields(
        _ content: String
    ) -> [String: SkillFrontmatter.Value]? {
        // CRLF is normalised first, matching the Go parser: a Swift Character
        // is a grapheme cluster and "\r\n" is ONE of them, so splitting on
        // "\n" would never match inside a CRLF file and the whole file would
        // parse as a single line with no frontmatter fence.
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        // The opening fence is matched exactly, not trimmed: Go tests the
        // literal prefix "---\n", so " ---" and "--- " open nothing.
        guard lines.first == "---" else { return nil }

        var fields: [String: SkillFrontmatter.Value] = [:]
        for line in lines.dropFirst() {
            if isClosingFence(line) { return fields }
            // A tab anywhere in the indentation is a hard yaml.v3 scanner
            // error, comment lines included.
            guard !line.hasPrefix("\t") else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Key lines live at column zero. An indented line belongs to the
            // previous entry — a nested mapping, a sequence, a folded
            // continuation — none of which this flat parser can represent, so
            // it refuses the file instead of reading the line as a key of its
            // own (which is what silently disagreed with Go before).
            guard line.first != " ",
                  let separator = keySeparator(trimmed),
                  // The key gets the same scrutiny as the value: a structural
                  // key (`- foo:`, `[a]:`, `*a:`) is a file yaml.v3 refuses,
                  // and a quoted key is unquoted here exactly as Go unquotes
                  // it — so `"description": x` fills the description, and a
                  // plain key collides with its quoted spelling as the
                  // duplicate Go calls it.
                  let key = SkillFrontmatter.key(trimmed[..<separator]),
                  let value = SkillFrontmatter.value(trimmed[trimmed.index(after: separator)...]),
                  fields[key] == nil
            else { return nil }
            fields[key] = value
        }
        return nil
    }

    /// The colon separating key from value: the first one followed by a space,
    /// a tab, or the end of the line, exactly as YAML defines it. nil means the
    /// line is not a mapping entry at all — `description:foo` has a colon but
    /// no separator, and yaml.v3 refuses it.
    nonisolated private static func keySeparator(_ trimmed: String) -> String.Index? {
        var index = trimmed.startIndex
        while let colon = trimmed[index...].firstIndex(of: ":") {
            let after = trimmed.index(after: colon)
            if after == trimmed.endIndex || trimmed[after] == " " || trimmed[after] == "\t" {
                return colon
            }
            index = after
        }
        return nil
    }

    /// The closing fence, matched the way Go's `splitFrontmatter` does: the
    /// line is right-trimmed of spaces and tabs, so `---  ` closes the block
    /// but `  ---` is an ordinary (and therefore rejected) content line.
    nonisolated private static func isClosingFence(_ line: Substring) -> Bool {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" else { break }
            end = previous
        }
        return line[line.startIndex..<end] == "---"
    }

    /// The AVAILABLE SKILLS system-prompt block, or nil when no enabled skill
    /// exists — so a surface with no skills keeps a byte-identical prompt
    /// (the sentinel-gate precedent).
    package nonisolated static func promptBlock(
        dir: String? = defaultDir()
    ) -> String? {
        let matching = list(dir: dir).filter(\.enabled)
        guard !matching.isEmpty else { return nil }
        let lines = matching.map { "- \($0.name) — \($0.description)" }.joined(separator: "\n")
        return """
        === AVAILABLE SKILLS ===
        \(lines)
        If a skill above is relevant to the user's request, FIRST call the `load_skill` MCP tool \
        with that skill's name and follow the returned instructions.
        """
    }

    /// `promptBlock` addressed the way a chat VM knows itself — by the
    /// `context_type` it stores on its conversation — so the set of surfaces
    /// that list skills is read from `chatContextTypes` instead of being
    /// hardcoded five times. An unlisted context type gets no block at all: a
    /// surface nobody added must not inherit skills by accident.
    package nonisolated static func promptBlock(
        contextType: String,
        dir: String? = defaultDir()
    ) -> String? {
        guard chatContextTypes.contains(contextType) else { return nil }
        return promptBlock(dir: dir)
    }
}
