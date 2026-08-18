import Foundation

// MARK: - Persona Skills catalog (Swift side of the dual-path)
//
// Reads `<workspace>/skills/*.md` — the persona-skill files the Go side
// deploys and parses in `internal/skills/`. This is a deliberate dual-path
// (the `saveNotes` precedent): the file format is the single source of truth
// shared by both sides, so the parsing semantics here MUST stay equivalent to
// the Go parser — filename stem is the identity (`^[a-z0-9][a-z0-9-]*$`),
// frontmatter between `---` lines carries `description` (required non-empty),
// `persona` (secretary | assistant | both), and `enabled` (optional, default
// true). Invalid files are skipped, never fatal; unknown frontmatter keys are
// ignored. Equivalence is pinned by matching fixtures in the `internal/skills`
// tests and `SkillsCatalogTests`.

/// Persona a skill targets. Raw values are the literal frontmatter tokens.
package enum SkillPersona: String, Sendable, Equatable {
    case secretary
    case assistant
    case both
}

/// One parsed skill file's listing-level data (the body stays on disk — it is
/// served by the `load_skill` MCP tool, never inlined into the system prompt).
package struct SkillSummary: Sendable, Equatable {
    package let name: String
    package let description: String
    package let persona: SkillPersona
    package let enabled: Bool

    package init(name: String, description: String, persona: SkillPersona, enabled: Bool) {
        self.name = name
        self.description = description
        self.persona = persona
        self.enabled = enabled
    }
}

package enum SkillsCatalog {
    /// Chat `context_type` → persona. One mapping table per side (the Go twin
    /// lives in `internal/skills`); mirrors the pinned persona contract in
    /// `docs/review/review-rules.md` ("Personas & chat contracts").
    package static let personaByContextType: [String: SkillPersona] = [
        "situation": .secretary,
        "meeting": .secretary,
        "target": .assistant,
        "track": .assistant,
        "idea": .assistant
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

    /// Parse one skill file's frontmatter. Strict on what matters, lenient
    /// elsewhere: nil (skip) on an illegal name, a missing/unterminated
    /// frontmatter block, an empty `description`, or a missing/unknown
    /// `persona`; unknown keys are ignored; `enabled` defaults to true and
    /// only a literal `false` turns it off. Line-based `key: value` parsing —
    /// same semantics as the Go parser (see the dual-path note at the top of
    /// this file).
    package nonisolated static func parse(name: String, content: String) -> SkillSummary? {
        guard isValidSkillName(name) else { return nil }
        // CRLF is normalised first, matching the Go parser: a Swift Character
        // is a grapheme cluster and "\r\n" is ONE of them, so splitting on
        // "\n" would never match inside a CRLF file and the whole file would
        // parse as a single line with no frontmatter fence.
        let content = content.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines = lines.dropFirst()

        var fields: [String: String] = [:]
        var terminated = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                terminated = true
                break
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Strip an inline YAML comment, then surrounding matching quotes.
            if let hash = value.firstIndex(of: "#"), value.first != "\"", value.first != "'" {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            if value.count >= 2,
               let first = value.first, first == "\"" || first == "'",
               value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = String(value)
        }
        guard terminated else { return nil }

        guard let description = fields["description"], !description.isEmpty else { return nil }
        guard let personaRaw = fields["persona"],
              let persona = SkillPersona(rawValue: personaRaw)
        else { return nil }
        let enabled = fields["enabled"]?.lowercased() != "false"
        return SkillSummary(name: name, description: description, persona: persona, enabled: enabled)
    }

    /// The AVAILABLE SKILLS system-prompt block for one persona, or nil when
    /// no enabled skill matches (persona match = exact or `both`) — so a
    /// surface with no skills keeps a byte-identical prompt (the
    /// sentinel-gate precedent).
    package nonisolated static func promptBlock(
        persona: SkillPersona,
        dir: String? = defaultDir()
    ) -> String? {
        let matching = list(dir: dir).filter {
            $0.enabled && ($0.persona == persona || $0.persona == .both)
        }
        guard !matching.isEmpty else { return nil }
        let lines = matching.map { "- \($0.name) — \($0.description)" }.joined(separator: "\n")
        return """
        === AVAILABLE SKILLS ===
        \(lines)
        If a skill above is relevant to the user's request, FIRST call the `load_skill` MCP tool \
        with that skill's name and follow the returned instructions.
        """
    }
}
