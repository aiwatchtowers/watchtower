import Foundation

/// One usage in the Usages inspector: `line  text` with the name cut out
/// for bold (spec §8.3).
package struct UsageRow: Equatable, Identifiable, Sendable {
    /// The line's text around the name, its indent dropped.
    package struct Parts: Equatable, Sendable {
        package let before: String
        package let name: String
        package let after: String

        package init(before: String, name: String, after: String) {
            self.before = before
            self.name = name
            self.after = after
        }
    }

    package let path: String
    package let line: Int
    /// The match's 1-based UTF-16 column in the full line.
    package let col: Int
    package let parts: Parts

    package var id: String {
        "\(path):\(line):\(col)"
    }

    /// Where a click goes.
    package var target: OpenQuicklyTarget {
        OpenQuicklyTarget(path: path, line: line, col: col)
    }

    init(match: CodeSearchMatch, word: String) {
        path = match.path
        line = match.line
        col = match.col
        parts = Self.parts(of: match.text, nameAt: match.textCol, length: word.utf16.count)
    }

    /// `text` split at the name (`textCol` 1-based, UTF-16, as the CLI
    /// reports it), the leading indent dropped before the name. A column
    /// that does not fit the text leaves the line plain.
    static func parts(of text: String, nameAt textCol: Int, length: Int) -> Parts {
        let line = text as NSString
        let start = textCol - 1
        guard start >= 0, length > 0, start + length <= line.length else {
            return Parts(before: text.trimmingLeadingWhitespace(), name: "", after: "")
        }
        let before = line.substring(to: start)
        return Parts(
            before: before.trimmingLeadingWhitespace(),
            name: line.substring(with: NSRange(location: start, length: length)),
            after: line.substring(from: start + length)
        )
    }
}

/// The usages found in one file.
package struct UsageGroup: Equatable, Identifiable, Sendable {
    package let path: String
    package fileprivate(set) var rows: [UsageRow]

    package var id: String {
        path
    }
}

/// Where the search behind the list is.
package enum UsagesStatus: Equatable, Sendable {
    case searching
    /// `truncated`: the search's `--max` stopped it.
    case finished(truncated: Bool)
    case failed(String)
    /// Cancelled before its end (the Files pane went away).
    case stopped
}

/// The Usages inspector's list for one name (spec §8.3): the matches of
/// `code search --word --case` grouped per file, files and rows in the
/// order they arrive; a collapsed file stays collapsed while matches
/// stream in. A new name is a new model.
package struct UsagesModel: Equatable, Sendable {
    package let word: String
    package private(set) var groups: [UsageGroup] = []
    package private(set) var count = 0
    package private(set) var status = UsagesStatus.searching
    private var collapsed: Set<String> = []
    /// Path → index in `groups`.
    private var groupIndex: [String: Int] = [:]
    private var seen: Set<String> = []

    package init(word: String) {
        self.word = word
    }

    package var header: String {
        "Usages — \(word) · \(count)"
    }

    /// The line under the list, nil when the list says it all.
    package var statusText: String? {
        switch status {
        case .searching:
            "Searching…"
        case .finished(truncated: true):
            "Showing the first \(count) \(count == 1 ? "match" : "matches")."
        case .finished:
            groups.isEmpty ? "No usages of \(word) found." : nil
        case let .failed(message):
            "The search failed: \(message)"
        case .stopped:
            "The search stopped before it finished."
        }
    }

    /// A match of the running search; one after the end is dropped.
    package mutating func append(_ match: CodeSearchMatch) {
        guard status == .searching else { return }
        let row = UsageRow(match: match, word: word)
        guard seen.insert(row.id).inserted else { return }
        if let index = groupIndex[row.path] {
            groups[index].rows.append(row)
        } else {
            groupIndex[row.path] = groups.count
            groups.append(UsageGroup(path: row.path, rows: [row]))
        }
        count += 1
    }

    package mutating func finish(truncated: Bool) {
        end(.finished(truncated: truncated))
    }

    package mutating func fail(_ message: String) {
        end(.failed(message))
    }

    package mutating func stop() {
        end(.stopped)
    }

    /// The first end stays.
    private mutating func end(_ status: UsagesStatus) {
        guard self.status == .searching else { return }
        self.status = status
    }

    package func isCollapsed(_ path: String) -> Bool {
        collapsed.contains(path)
    }

    package mutating func setCollapsed(_ isCollapsed: Bool, path: String) {
        if isCollapsed {
            collapsed.insert(path)
        } else {
            collapsed.remove(path)
        }
    }
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
