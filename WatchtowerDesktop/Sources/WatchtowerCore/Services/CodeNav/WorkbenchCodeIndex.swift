import Foundation
import Observation

/// Which kind of run a batch of index lines came from. Either way a file
/// line is a workbench file (`lang` "" = a language the CLI does not index)
/// unless it is `skipped` (ruling R21: ignored, binary, oversized, …), which
/// takes the path out of the index like `deleted`.
package enum CodeIndexRunKind: Sendable {
    /// `code index --json` over the whole folder: what it does not list is
    /// dropped when it finishes.
    case fullRun
    /// A `--serve` request for changed paths.
    case update
}

/// One workbench's symbol index, in memory (spec §7): the files the CLI
/// listed and the symbols of each, fed by `CodeIndexCenter` and queried by
/// Open Quickly, go to definition and the jump bar. While a run is in
/// flight, queries answer from what is applied so far.
@MainActor
@Observable
package final class WorkbenchCodeIndex {
    private struct Entry {
        let file: String
        /// As the CLI reported it; "" = a language it does not index.
        var lang: String
        /// false = `"defs":false` (ruling R32).
        var holdsDefinitions: Bool
        /// UTF-16 offset of the file name in the path.
        let nameStart: Int
        let nameSlot: Int
        let pathSlot: Int
        /// By line.
        var symbols: [CodeSymbol]
        /// Per symbol: its corpus slot, -1 for an outline entry (not listed
        /// by Open Quickly).
        var symbolSlots: [Int]
    }

    /// What a corpus slot stands for.
    private struct SlotOwner {
        static let nameSlot = -1
        static let pathSlot = -2

        let entry: Int
        /// Into `Entry.symbols`, or `nameSlot`/`pathSlot`.
        let symbol: Int
        /// The symbol's `CodeSymbolKind.rankGroup`.
        var group = 0
    }

    private enum Tag {
        static let name: UInt8 = 1
        static let path: UInt8 = 2
        static let symbol: UInt8 = 4
    }

    package var state: CodeIndexState = .idle
    /// Why the owner's rules file was ignored, as the last done line said
    /// (spec §6.5); nil once a run loads it (or there is none).
    package private(set) var rulesError: String?
    /// Every file, in the order the CLI first reported it.
    package private(set) var files: [String] = []
    /// By entry id (stable while the file stays).
    private var entries: [Int: Entry] = [:]
    @ObservationIgnored private var position: [String: Int] = [:]
    @ObservationIgnored private var nextEntryID = 0
    @ObservationIgnored private var corpus = FuzzyCorpus()
    @ObservationIgnored private var owners: [SlotOwner] = []
    /// name → the files defining it.
    @ObservationIgnored private var definitions: [String: Set<String>] = [:]
    @ObservationIgnored private var seenInFullRun: Set<String>?

    package init() {}

    /// Symbols named exactly `name` (case-sensitive), in file order.
    package func symbols(named name: String) -> [CodeSymbol] {
        guard let paths = definitions[name] else { return [] }
        return files.filter(paths.contains).flatMap { path in
            symbols(in: path).filter { $0.name == name }
        }
    }

    /// The language go to definition and the jump bar see in `path`: as
    /// reported, but "" for one whose files hold no code definitions
    /// (markup, styles, config — ruling R32), so navigation treats it as
    /// unsupported; nil when the file is not in the index (yet).
    package func definitionLanguage(of path: String) -> String? {
        guard let entry = position[path].flatMap({ entries[$0] }) else { return nil }
        return entry.holdsDefinitions ? entry.lang : ""
    }

    /// The symbols of one file, by line.
    package func symbols(in path: String) -> [CodeSymbol] {
        position[path].flatMap { entries[$0]?.symbols } ?? []
    }

    // MARK: Applying runs

    package func applyIndexLines(_ lines: [CodeIndexLine], from kind: CodeIndexRunKind) {
        var gone = Set<String>()
        for line in lines {
            switch line {
            case let .file(result):
                guard !result.skipped else {
                    gone.insert(result.file)
                    continue
                }
                if kind == .fullRun { seenInFullRun?.insert(result.file) }
                gone.remove(result.file)
                upsert(result)
            case let .deleted(path):
                gone.formUnion(subtree(path))
            case let .done(done):
                // Every done line carries it: set only on a change, so views
                // are not invalidated by each update.
                if rulesError != done.rulesError { rulesError = done.rulesError }
            }
        }
        removeFiles(gone)
    }

    /// A full run starts: files it does not list are dropped when it finishes.
    package func beginFullRun() {
        seenInFullRun = []
    }

    /// The full run reached its done line.
    package func finishFullRun() {
        guard let seen = seenInFullRun else { return }
        seenInFullRun = nil
        removeFiles(Set(files.filter { !seen.contains($0) }))
    }

    /// A full run that did not finish keeps everything it had.
    package func abandonFullRun() {
        seenInFullRun = nil
    }

    private func upsert(_ result: CodeIndexFileResult) {
        let symbols = result.symbols.enumerated()
            .sorted { a, b in (a.element.line, a.element.col, a.offset) < (b.element.line, b.element.col, b.offset) }
            .map(\.element)
        if let id = position[result.file], var entry = entries[id] {
            unlinkDefinitions(entry.symbols, path: result.file)
            entry.symbolSlots.filter { $0 >= 0 }.forEach { corpus.killSlot($0) }
            entry.symbols = symbols
            entry.lang = result.lang
            entry.holdsDefinitions = result.holdsDefinitions
            entry.symbolSlots = symbolSlots(symbols, entry: id)
            entries[id] = entry
        } else {
            let id = nextEntryID
            nextEntryID += 1
            let name = CodeRanking.fileName(result.file)
            let nameSlot = addSlot(name, tag: Tag.name, SlotOwner(entry: id, symbol: SlotOwner.nameSlot))
            let pathSlot = addSlot(result.file, tag: Tag.path, SlotOwner(entry: id, symbol: SlotOwner.pathSlot))
            position[result.file] = id
            entries[id] = Entry(
                file: result.file, lang: result.lang, holdsDefinitions: result.holdsDefinitions,
                nameStart: result.file.utf16.count - name.utf16.count, nameSlot: nameSlot, pathSlot: pathSlot,
                symbols: symbols, symbolSlots: symbolSlots(symbols, entry: id)
            )
            files.append(result.file)
        }
        for symbol in symbols { definitions[symbol.name, default: []].insert(result.file) }
    }

    private func symbolSlots(_ symbols: [CodeSymbol], entry: Int) -> [Int] {
        symbols.enumerated().map { k, symbol in
            symbol.outline ? -1 : addSlot(symbol.name, tag: Tag.symbol, SlotOwner(entry: entry, symbol: k, group: symbol.kind.rankGroup))
        }
    }

    private func addSlot(_ text: String, tag: UInt8, _ owner: SlotOwner) -> Int {
        owners.append(owner)
        return corpus.appendCandidate(text, tag: tag)
    }

    /// `path` and, for a deleted folder, every file under it.
    private func subtree(_ path: String) -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.filter { $0 == path || $0.hasPrefix(prefix) }
    }

    private func removeFiles(_ paths: Set<String>) {
        let doomed = paths.filter { position[$0] != nil }
        guard !doomed.isEmpty else { return }
        for path in doomed {
            guard let id = position.removeValue(forKey: path), let entry = entries.removeValue(forKey: id) else { continue }
            unlinkDefinitions(entry.symbols, path: path)
            ([entry.nameSlot, entry.pathSlot] + entry.symbolSlots.filter { $0 >= 0 }).forEach { corpus.killSlot($0) }
        }
        files.removeAll { doomed.contains($0) }
        if corpus.deadCount > max(4096, corpus.slotCount / 2) { rebuildCorpus() }
    }

    /// Reclaims the slots of removed and re-indexed files.
    private func rebuildCorpus() {
        corpus = FuzzyCorpus()
        owners = []
        for path in files {
            guard let id = position[path], let old = entries[id] else { continue }
            let nameSlot = addSlot(CodeRanking.fileName(path), tag: Tag.name, SlotOwner(entry: id, symbol: SlotOwner.nameSlot))
            let pathSlot = addSlot(path, tag: Tag.path, SlotOwner(entry: id, symbol: SlotOwner.pathSlot))
            entries[id] = Entry(
                file: path, lang: old.lang, holdsDefinitions: old.holdsDefinitions, nameStart: old.nameStart, nameSlot: nameSlot, pathSlot: pathSlot,
                symbols: old.symbols, symbolSlots: symbolSlots(old.symbols, entry: id)
            )
        }
    }

    private func unlinkDefinitions(_ symbols: [CodeSymbol], path: String) {
        for name in Set(symbols.map(\.name)) {
            definitions[name]?.remove(path)
            if definitions[name]?.isEmpty == true { definitions[name] = nil }
        }
    }

    // MARK: Query

    /// Open Quickly's Files/Symbols matches for `text`, best first, at most
    /// `limit` (ranked as `CodeRanking`). An empty query lists files in
    /// boost order and no symbols; the Text scope is `code search`'s, so it
    /// answers nothing here.
    package func query(_ text: String, scope: CodeSearchScope, boosts: CodeRankingBoosts, limit: Int = 100) -> [CodeQuickResult] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard scope != .text, limit > 0 else { return [] }
        guard !trimmed.isEmpty else {
            guard scope != .symbols else { return [] }
            return CodeRanking.emptyQueryOrder(files: files, boosts: boosts).prefix(limit).map {
                CodeQuickResult(item: .file(path: $0), score: 0, titleMatches: [], pathMatches: [])
            }
        }
        let matcher = FuzzyMatcher(query: trimmed)
        let acrossFolders = trimmed.contains("/")
        let fileTags = acrossFolders ? Tag.path : Tag.name | Tag.path
        let tags = (scope == .symbols ? 0 : fileTags) | (scope == .files ? 0 : Tag.symbol)
        let boostByEntry = entryBoosts(boosts)
        var top = CodeTopRanked(limit: limit)
        var nameHit: (entry: Int, score: Int)?
        let hits = matcher.scanCorpus(corpus, tags: tags)
        var index = 0
        while index < hits.count {
            let hit = hits[index]
            index += 1
            let owner = owners[hit.slot]
            let boost = boostByEntry.isEmpty ? 0 : boostByEntry[owner.entry] ?? 0
            switch owner.symbol {
            case SlotOwner.nameSlot:
                // A file's name slot comes right before its path slot, and a
                // name hit implies a path hit: a name match outranks the path's.
                nameHit = (owner.entry, hit.score)
                continue
            case SlotOwner.pathSlot:
                break
            default:
                top.offer(total: hit.score + boost + owner.group * CodeRanking.kindBonus, entry: owner.entry, symbol: owner.symbol)
                continue
            }
            let score = nameHit?.entry == owner.entry ? (nameHit?.score ?? 0) + Self.nameMatchBonus : hit.score
            top.offer(total: score + boost, entry: owner.entry, symbol: -1)
        }
        return top.rankedHits().compactMap { result($0, matcher, acrossFolders: acrossFolders) }
    }

    private static let nameMatchBonus = 16

    /// The boost of each boosted file's entry, built once per query.
    private func entryBoosts(_ boosts: CodeRankingBoosts) -> [Int: Int] {
        let tiers = CodeBoostTiers(boosts)
        var out: [Int: Int] = [:]
        for path in boosts.openTabs + boosts.recent + Array(boosts.gitModified) {
            if let id = position[path] { out[id] = tiers.tier(of: path) * CodeRanking.tierBonus }
        }
        return out
    }

    private func result(_ hit: CodeTopRanked.Hit, _ matcher: FuzzyMatcher, acrossFolders: Bool) -> CodeQuickResult? {
        guard let entry = entries[hit.entry] else { return nil }
        if hit.symbol >= 0 {
            let symbol = entry.symbols[hit.symbol]
            guard let match = matcher.fuzzyMatch(corpus, slot: entry.symbolSlots[hit.symbol]) else { return nil }
            return CodeQuickResult(item: .symbol(symbol), score: hit.total, titleMatches: match.matched, pathMatches: [])
        }
        if !acrossFolders, let match = matcher.fuzzyMatch(corpus, slot: entry.nameSlot) {
            return CodeQuickResult(item: .file(path: entry.file), score: hit.total, titleMatches: match.matched, pathMatches: [])
        }
        guard let match = matcher.fuzzyMatch(corpus, slot: entry.pathSlot) else { return nil }
        let inName = match.matched.filter { $0 >= entry.nameStart }.map { $0 - entry.nameStart }
        return CodeQuickResult(item: .file(path: entry.file), score: hit.total, titleMatches: inName, pathMatches: match.matched)
    }
}

/// The best `limit` hits of a query, kept in a min-heap as they are offered
/// (no sort of every match on a one-letter query). Ordered as
/// `CodeRanking.rank`: higher total first, then offer order.
struct CodeTopRanked {
    struct Hit {
        let total: Int
        let order: Int
        let entry: Int
        /// -1 = the file itself.
        let symbol: Int

        /// Ranks below `other`.
        func isWorse(than other: Self) -> Bool {
            total != other.total ? total < other.total : order > other.order
        }
    }

    private let limit: Int
    private var heap: [Hit] = []
    private var offered = 0

    init(limit: Int) {
        self.limit = limit
        heap.reserveCapacity(limit)
    }

    mutating func offer(total: Int, entry: Int, symbol: Int) {
        let hit = Hit(total: total, order: offered, entry: entry, symbol: symbol)
        offered += 1
        if heap.count < limit {
            heap.append(hit)
            siftUp(heap.count - 1)
        } else if heap[0].isWorse(than: hit) {
            heap[0] = hit
            siftDown(0)
        }
    }

    func rankedHits() -> [Hit] {
        heap.sorted { $1.isWorse(than: $0) }
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].isWorse(than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            var worst = parent
            for child in [2 * parent + 1, 2 * parent + 2] where child < heap.count && heap[child].isWorse(than: heap[worst]) {
                worst = child
            }
            guard worst != parent else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }
}
