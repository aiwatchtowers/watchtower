import Foundation
import WatchtowerCore

/// One skill file as the Settings list renders it.
///
/// `shipped` is the origin badge: shipped skills are the ones the Go daemon
/// deploys from `internal/skills/shipped/` and may resurrect after a delete,
/// so the UI offers them a disable toggle but never a Delete button.
struct SkillRow: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let persona: SkillPersona
    let enabled: Bool
    let shipped: Bool
}

/// The editor sheet's working copy of one skill file. `name` is the filename
/// stem and is locked once the file exists (renaming would orphan the deploy
/// sidecar's digest bookkeeping on the Go side).
struct SkillDraft: Equatable, Sendable {
    var name: String
    var description: String
    var persona: SkillPersona
    var body: String

    static func empty() -> Self {
        Self(name: "", description: "", persona: .secretary, body: "")
    }
}

/// Settings → Skills card backing store.
///
/// Skill files are the single source of truth (no DB, no UserDefaults — see
/// `docs/superpowers/specs/2026-08-19-persona-skills-design.md`), so every
/// operation here is a synchronous file write against
/// `<workspace>/skills/<name>.md` and the list is re-read from disk right
/// after. Reading and validation go through `SkillsCatalog`, the same parser
/// the chat prompt builders use, so the card can never show a skill the
/// personas do not see.
@MainActor
@Observable
final class SkillsSettingsViewModel {
    private(set) var rows: [SkillRow] = []
    var error: String?

    /// The skills directory. `nil` when no workspace is active — the card then
    /// renders its empty state and every write is refused rather than guessing
    /// a path.
    let dir: String?

    init(dir: String? = SkillsCatalog.defaultDir()) {
        self.dir = dir
    }

    // MARK: - Load

    func load() {
        guard let dir else {
            rows = []
            return
        }
        rows = SkillsCatalog.list(dir: dir).map { summary in
            SkillRow(
                name: summary.name,
                description: summary.description,
                persona: summary.persona,
                enabled: summary.enabled,
                shipped: summary.shipped
            )
        }
    }

    // MARK: - Enable toggle

    /// Flip one skill's `enabled` frontmatter key in place. Every other byte of
    /// the file — body, unknown frontmatter keys, indentation, CRLF line
    /// endings — is preserved: the owner may have edited a shipped skill, and
    /// a toggle must never be the thing that rewrites their prose.
    @discardableResult
    func setEnabled(name: String, enabled: Bool) -> Bool {
        guard let path = path(for: name) else { return false }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            error = "Could not read \(name).md"
            return false
        }
        guard let updated = SkillFileEditor.settingEnabled(enabled, in: content) else {
            error = "\(name).md has no frontmatter block to update"
            return false
        }
        guard write(updated, to: path) else { return false }
        error = nil
        load()
        return true
    }

    // MARK: - Editor

    /// The current on-disk state of one skill, for the editor sheet. `nil` when
    /// the file is missing or unparsable — the sheet then refuses to open
    /// rather than silently offering a blank file that Save would overwrite.
    func draft(for name: String) -> SkillDraft? {
        guard let path = path(for: name),
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              let summary = SkillsCatalog.parse(name: name, content: content),
              let parts = SkillFileEditor.split(content)
        else { return nil }
        return SkillDraft(
            name: name,
            description: summary.description,
            persona: summary.persona,
            body: parts.body
        )
    }

    /// Write a new or edited skill file. Returns false (and sets `error`) on a
    /// validation failure or a write failure, so the sheet can stay open.
    ///
    /// `enabled` and any unknown frontmatter keys already on disk are carried
    /// through — including the `x-watchtower-shipped` marker, so editing a
    /// shipped skill does not silently reclassify it as owner-created and let
    /// a later Delete fight the daemon's re-deploy.
    @discardableResult
    func save(_ draft: SkillDraft, isNew: Bool) -> Bool {
        guard let dir else {
            error = "No active workspace — cannot save skills."
            return false
        }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard SkillsCatalog.isValidSkillName(name) else {
            error = "Name must be lowercase letters, digits and hyphens (e.g. status-update)."
            return false
        }
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            error = "Description is required — it is what the persona sees when picking a skill."
            return false
        }
        let path = "\(dir)/\(name).md"
        let exists = FileManager.default.fileExists(atPath: path)
        if isNew && exists {
            error = "A skill named \(name) already exists."
            return false
        }

        var enabled = true
        var extras: [String] = []
        if exists, let content = try? String(contentsOfFile: path, encoding: .utf8),
           let parts = SkillFileEditor.split(content) {
            enabled = parts.enabled
            extras = parts.extraFrontmatterLines
        }

        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        } catch {
            self.error = "Could not create the skills directory: \(error.localizedDescription)"
            return false
        }

        let content = SkillFileEditor.compose(
            description: description,
            persona: draft.persona,
            enabled: enabled,
            extraFrontmatterLines: extras,
            body: draft.body
        )
        // Round-trip guard: the composed file goes through `SkillsCatalog`, the
        // same parser the chat prompts use, before it is written. That is a
        // Swift-side check only — it proves the file will not vanish from the
        // personas, and since the catalog accepts a strict subset of what
        // yaml.v3 does (see the note atop SkillsCatalog.swift), a file that
        // passes it also parses on the Go side; the reverse is not implied.
        guard SkillsCatalog.parse(name: name, content: content) != nil else {
            error = "This skill could not be saved in a readable form — check the description "
                + "and any custom frontmatter lines."
            return false
        }
        guard write(content, to: path) else { return false }
        error = nil
        load()
        return true
    }

    /// Delete an owner-created skill. Shipped skills are refused: the daemon's
    /// `Deploy` would write them straight back, so disabling is the only honest
    /// off switch for them.
    @discardableResult
    func delete(name: String) -> Bool {
        guard let dir, let path = path(for: name) else { return false }
        guard !isShipped(name: name, dir: dir) else {
            error = "Shipped skills can only be disabled, not deleted."
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            self.error = "Could not delete \(name).md: \(error.localizedDescription)"
            return false
        }
        error = nil
        load()
        return true
    }

    // MARK: - Helpers

    /// Origin detection reads the file itself: shipped skills carry an
    /// `x-watchtower-shipped` frontmatter marker written by `internal/skills`
    /// (an ordinary unknown key to both parsers). Deliberately not the deploy
    /// sidecar — a file already on disk answers the question without a second
    /// format to keep in sync, and it keeps answering it after the owner edits
    /// the file, which is exactly when the answer matters.
    private func isShipped(name: String, dir: String) -> Bool {
        guard let content = try? String(contentsOfFile: "\(dir)/\(name).md", encoding: .utf8),
              let parts = SkillFileEditor.split(content)
        else { return false }
        return parts.shipped
    }

    private func path(for name: String) -> String? {
        guard let dir else {
            error = "No active workspace — cannot edit skills."
            return nil
        }
        guard SkillsCatalog.isValidSkillName(name) else {
            error = "Invalid skill name: \(name)"
            return nil
        }
        return "\(dir)/\(name).md"
    }

    private func write(_ content: String, to path: String) -> Bool {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            self.error = "Could not write \(path): \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Skill file surgery

/// Pure text operations on a skill file. Kept free of the ViewModel so the
/// byte-preservation rules below are directly testable.
enum SkillFileEditor {
    struct Parts: Equatable {
        /// Frontmatter lines other than description/persona/enabled, verbatim
        /// (terminators stripped) — carried through by `compose`.
        var extraFrontmatterLines: [String]
        /// Already resolved against the format's default (absent key = on).
        var enabled: Bool
        var shipped: Bool
        var body: String
    }

    /// Split a skill file into its recognised frontmatter fields and its body.
    /// Returns nil when there is no terminated frontmatter block.
    static func split(_ content: String) -> Parts? {
        let ls = lines(of: content)
        guard let close = closingFenceIndex(ls) else { return nil }

        var extras: [String] = []
        var enabled = true
        var shipped = false
        for index in 1..<close {
            let text = stripTerminator(ls[index])
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else {
                if !trimmed.isEmpty { extras.append(String(text)) }
                continue
            }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            switch key {
            case "description", "persona":
                continue
            case "enabled":
                // Read through the shared interpreter, not a local string
                // compare: the catalog and this editor must agree on what
                // "off" looks like, or a Save would silently re-enable a skill
                // the owner switched off (e.g. `enabled: false # too noisy`,
                // or `enabled: no`).
                switch SkillFrontmatter.bool(trimmed[trimmed.index(after: colon)...]) {
                case .off:
                    enabled = false
                case .on, .unset, .invalid:
                    // `invalid` is a value neither parser can read, so the file
                    // is unlistable anyway; composing it back with the format's
                    // default repairs it rather than guessing an intent.
                    enabled = true
                }
            case "x-watchtower-shipped":
                shipped = true
                extras.append(String(text))
            default:
                extras.append(String(text))
            }
        }

        var body = ls[(close + 1)...].joined()
        while let first = body.first, first == "\n" || first == "\r\n" {
            body = String(body.dropFirst())
        }
        return Parts(
            extraFrontmatterLines: extras, enabled: enabled, shipped: shipped, body: body
        )
    }

    /// Rewrite the frontmatter `enabled` key, preserving every other byte of
    /// the file (body, unknown keys, key order, indentation, CRLF endings). The
    /// key is inserted just above the closing fence when the file has none.
    /// Returns nil when there is no terminated frontmatter block.
    static func settingEnabled(_ enabled: Bool, in content: String) -> String? {
        let ls = lines(of: content)
        guard let close = closingFenceIndex(ls) else { return nil }
        let value = enabled ? "true" : "false"
        var out = ls.map(String.init)

        for index in 1..<close {
            let text = stripTerminator(ls[index])
            guard let colon = text.firstIndex(of: ":") else { continue }
            guard text[..<colon].trimmingCharacters(in: .whitespaces) == "enabled" else { continue }
            let indent = String(text.prefix { $0 == " " || $0 == "\t" })
            out[index] = "\(indent)enabled: \(value)\(terminator(of: ls[index]))"
            return out.joined()
        }

        let fenceTerminator = terminator(of: ls[close])
        out.insert("enabled: \(value)\(fenceTerminator.isEmpty ? "\n" : fenceTerminator)", at: close)
        return out.joined()
    }

    /// Render a whole skill file from the editor's fields.
    static func compose(
        description: String,
        persona: SkillPersona,
        enabled: Bool,
        extraFrontmatterLines: [String],
        body: String
    ) -> String {
        var out = "---\n"
        out += "description: \(yamlScalar(description))\n"
        out += "persona: \(persona.rawValue)\n"
        out += "enabled: \(enabled ? "true" : "false")\n"
        for line in extraFrontmatterLines {
            out += "\(line)\n"
        }
        out += "---\n\n"
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            out += trimmedBody + "\n"
        }
        return out
    }

    /// Render a frontmatter value as a single-quoted YAML scalar, always.
    ///
    /// Single quoting has exactly one escape — a literal `'` is doubled — and
    /// it suspends every indicator (`#`, `:`, `-`, `[`, `{`, `&`, `*`, …) at
    /// once, so no blacklist of "characters that would need quoting" has to be
    /// kept correct on two sides of the dual-path. Newlines are still folded to
    /// spaces: the description is one line by construction.
    static func yamlScalar(_ value: String) -> String {
        let flat = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "'\(flat.replacingOccurrences(of: "'", with: "''"))'"
    }

    // MARK: - Line plumbing

    /// Split into lines, each keeping its own terminator, so a rewrite can put
    /// the untouched ones back verbatim.
    ///
    /// Character-wise, not `split(separator: "\n")`: a Swift `Character` is a
    /// grapheme cluster, and `"\r\n"` is ONE of them — searching for `"\n"`
    /// never matches inside a CRLF file, which would collapse the whole file
    /// into a single "line" and lose the frontmatter fence.
    private static func lines(of content: String) -> [Substring] {
        var result: [Substring] = []
        var start = content.startIndex
        var index = content.startIndex
        while index < content.endIndex {
            let next = content.index(after: index)
            if content[index] == "\n" || content[index] == "\r\n" {
                result.append(content[start..<next])
                start = next
            }
            index = next
        }
        if start < content.endIndex {
            result.append(content[start...])
        }
        return result
    }

    private static func terminator(of line: Substring) -> String {
        guard let last = line.last else { return "" }
        return (last == "\n" || last == "\r\n") ? String(last) : ""
    }

    private static func stripTerminator(_ line: Substring) -> Substring {
        guard let last = line.last, last == "\n" || last == "\r\n" else { return line }
        return line.dropLast()
    }

    /// Index of the frontmatter's closing `---`, or nil when the file does not
    /// open with a fence or never closes it.
    ///
    /// Fences are matched the way `SkillsCatalog.isClosingFence` and Go's
    /// `splitFrontmatter` match them: the opening one exactly, the closing one
    /// right-trimmed of spaces and tabs. An indented `  ---` is ordinary
    /// content to all three, so the editor can never treat as a fence a line
    /// the catalog reads as the file's first broken key.
    private static func closingFenceIndex(_ ls: [Substring]) -> Int? {
        guard let first = ls.first, stripTerminator(first) == "---" else { return nil }
        for index in 1..<ls.count where isFence(ls[index]) {
            return index
        }
        return nil
    }

    private static func isFence(_ line: Substring) -> Bool {
        var text = stripTerminator(line)
        while let last = text.last, last == " " || last == "\t" {
            text = text.dropLast()
        }
        return text == "---"
    }
}
