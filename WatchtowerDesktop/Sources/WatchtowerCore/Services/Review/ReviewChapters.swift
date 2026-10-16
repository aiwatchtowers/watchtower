import Foundation

/// One deep-review chapter: a directory's changed files, tests first.
package struct ReviewChapter: Equatable, Sendable, Identifiable {
    package let key: String
    package let title: String
    package let paths: [String]
    package let changedLines: Int
    package let core: Bool
    /// Who split the diff: the session's agent, the overview model, or the mechanical rule.
    package let source: Source
    /// The lens ids this chapter shows; nil = all.
    package let lenses: [String]?
    package var id: String { key }

    package enum Source: String, Sendable { case agent, ai, mechanical }

    package init(
        key: String,
        title: String,
        paths: [String],
        changedLines: Int,
        core: Bool,
        source: Source = .mechanical,
        lenses: [String]? = nil
    ) {
        self.source = source
        self.lenses = lenses
        self.key = key
        self.title = title
        self.paths = paths
        self.changedLines = changedLines
        self.core = core
    }
}

/// A chapter proposed by the agent or the overview model, before validation.
package struct ReviewChapterSpec: Equatable, Sendable {
    package let title: String
    package let paths: [String]
    package let core: Bool
    package let lenses: [String]?

    package init(title: String, paths: [String], core: Bool, lenses: [String]?) {
        self.title = title
        self.paths = paths
        self.core = core
        self.lenses = lenses
    }
}

/// The mechanical chapter split (no model): by directory, a test next to its
/// one subject, capped at `maxChangedLines`, generated and lock files last.
package enum ReviewChapters {
    package static let maxChangedLines = 400

    private struct Unit {
        let sortKey: String
        let dir: String
        let paths: [String]
        let lines: Int
    }

    package static func mechanical(_ files: [ReviewDiffFile]) -> [ReviewChapter] {
        var lines: [String: Int] = [:]
        for file in files where lines[file.path] == nil { lines[file.path] = file.additions + file.deletions }
        let live = files.filter { $0.collapsedReason == nil }.map(\.path).sorted()
        let collapsed = files.filter { $0.collapsedReason != nil }.map(\.path)

        var subjectsByStem: [String: [String]] = [:]
        for path in live where !isTest(path) {
            subjectsByStem[stem(of: path, test: false), default: []].append(path)
        }
        var testsBySubject: [String: [String]] = [:]
        var standalone: [String] = []
        for path in live where isTest(path) {
            // A subject in the test's own directory first; else the one unique-stem subject anywhere (Swift Tests/).
            let all = subjectsByStem[stem(of: path, test: true)] ?? []
            let sameDir = all.filter { dirname($0) == dirname(path) }
            let subjects = sameDir.isEmpty ? all : sameDir
            if subjects.count == 1 {
                testsBySubject[subjects[0], default: []].append(path)
            } else {
                standalone.append(path)
            }
        }

        var units: [Unit] = []
        for path in live where !isTest(path) {
            let paths = (testsBySubject[path] ?? []) + [path]
            units.append(Unit(sortKey: path, dir: dirname(path), paths: paths, lines: paths.reduce(0) { $0 + (lines[$1] ?? 0) }))
        }
        for path in standalone {
            units.append(Unit(sortKey: path, dir: dirname(path), paths: [path], lines: lines[path] ?? 0))
        }
        units.sort { $0.sortKey < $1.sortKey }

        var dirOrder: [String] = []
        var byDir: [String: [Unit]] = [:]
        for unit in units {
            if byDir[unit.dir] == nil { dirOrder.append(unit.dir) }
            byDir[unit.dir, default: []].append(unit)
        }

        var chapters: [ReviewChapter] = []
        for dir in dirOrder {
            var parts: [[Unit]] = []
            var current: [Unit] = []
            var currentLines = 0
            for unit in byDir[dir] ?? [] {
                if !current.isEmpty, currentLines + unit.lines > maxChangedLines {
                    parts.append(current)
                    current = []
                    currentLines = 0
                }
                current.append(unit)
                currentLines += unit.lines
            }
            if !current.isEmpty { parts.append(current) }
            let base = dir.isEmpty ? "(root)" : dir
            for (index, part) in parts.enumerated() {
                let number = index + 1
                chapters.append(ReviewChapter(
                    key: number == 1 ? "dir:\(dir)" : "dir:\(dir)#\(number)",
                    title: number == 1 ? base : "\(base) (\(number))",
                    paths: part.flatMap(\.paths),
                    changedLines: part.reduce(0) { $0 + $1.lines },
                    core: false
                ))
            }
        }
        if !collapsed.isEmpty {
            chapters.append(ReviewChapter(
                key: "collapsed", title: "Generated and lock files", paths: collapsed, changedLines: 0, core: false
            ))
        }
        return chapters
    }

    /// The agent's chapters, else the AI's, else none; files no chosen chapter
    /// names go into mechanical chapters appended after (all empty = mechanical).
    package static func resolve(
        _ files: [ReviewDiffFile], agent: [ReviewChapterSpec], ai: [ReviewChapterSpec]
    ) -> [ReviewChapter] {
        var lines: [String: Int] = [:]
        for file in files where lines[file.path] == nil { lines[file.path] = file.additions + file.deletions }
        func build(_ specs: [ReviewChapterSpec], source: ReviewChapter.Source, prefix: String, taken: inout Set<String>) -> [ReviewChapter] {
            var out: [ReviewChapter] = []
            for (index, spec) in specs.enumerated() {
                var paths: [String] = []
                for path in spec.paths where lines[path] != nil && !taken.contains(path) {
                    taken.insert(path)
                    paths.append(path)
                }
                guard !paths.isEmpty else { continue }
                out.append(ReviewChapter(
                    key: "\(prefix):\(index + 1)", title: spec.title,
                    paths: paths.filter(isTest) + paths.filter { !isTest($0) },
                    changedLines: paths.reduce(0) { $0 + (lines[$1] ?? 0) },
                    core: spec.core, source: source, lenses: spec.lenses
                ))
            }
            return out.filter(\.core) + out.filter { !$0.core }
        }
        var taken = Set<String>()
        var chosen = build(agent, source: .agent, prefix: "agent", taken: &taken)
        if chosen.isEmpty { chosen = build(ai, source: .ai, prefix: "ai", taken: &taken) }
        if chosen.isEmpty { return mechanical(files) }
        let rest = files.filter { !taken.contains($0.path) }
        return chosen + (rest.isEmpty ? [] : mechanical(rest))
    }

    /// The lenses a chapter shows, in `all`'s order. An AI chapter shows what it
    /// marks plus house_rules and every owner lens.
    package static func lenses(for chapter: ReviewChapter, all: [ReviewLens]) -> [ReviewLens] {
        guard chapter.source == .ai, let marked = chapter.lenses else { return all }
        return all.filter { marked.contains($0.id) || $0.id == "house_rules" || !$0.builtin }
    }

    /// Reading time at 400 changed lines per hour, rounded up.
    package static func estimateMinutes(changedLines: Int) -> Int {
        guard changedLines > 0 else { return 0 }
        return (changedLines * 60 + 399) / 400
    }

    package static func isTest(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: { $0 == "Tests" || $0 == "tests" || $0 == "__tests__" }) { return true }
        let name = parts.last ?? path
        let base = (name as NSString).deletingPathExtension
        if base.hasSuffix("_test") || base.hasSuffix("Tests") || base.hasSuffix("Test") { return true }
        if base.hasSuffix(".test") || base.hasSuffix(".spec") || base.hasPrefix("test_") { return true }
        return false
    }

    package static func done(_ chapter: ReviewChapter, isViewed: (String) -> Bool) -> Bool {
        chapter.paths.allSatisfy(isViewed)
    }

    private static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func stem(of path: String, test: Bool) -> String {
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard test else { return name }
        for suffix in ["_test", "Tests", "Test", ".test", ".spec"] where name.hasSuffix(suffix) && name != suffix {
            name = String(name.dropLast(suffix.count))
            break
        }
        if name.hasPrefix("test_") { name = String(name.dropFirst(5)) }
        return name
    }
}

package struct ReviewProgress: Equatable, Sendable {
    package let viewedLines: Int
    package let totalLines: Int
    package let chaptersDone: Int
    package let chapterCount: Int

    package static func make(
        files: [ReviewDiffFile], chapters: [ReviewChapter], isViewed: (String) -> Bool
    ) -> Self {
        // Collapsed (generated, lock) files are not review work: they count in neither number.
        let counted = files.filter { $0.collapsedReason == nil }
        return Self(
            viewedLines: counted.filter { isViewed($0.path) }.reduce(0) { $0 + $1.additions + $1.deletions },
            totalLines: counted.reduce(0) { $0 + $1.additions + $1.deletions },
            chaptersDone: chapters.filter { ReviewChapters.done($0, isViewed: isViewed) }.count,
            chapterCount: chapters.count
        )
    }
}
