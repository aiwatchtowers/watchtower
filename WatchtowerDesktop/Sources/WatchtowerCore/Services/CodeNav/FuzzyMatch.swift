import Foundation

/// Open Quickly's matcher (spec §7): fzf-style subsequence scoring with
/// bonuses at word starts, camelCase humps and after path separators, and
/// for consecutive runs; smart case (exact once the query has an upper-case
/// letter; only ASCII letters fold). Offsets are UTF-16 units. Pure.
package enum FuzzyMatch {
    static let match: Int32 = 16
    static let gapStart: Int32 = 3
    static let gapExtension: Int32 = 1
    static let firstMultiplier: Int32 = 2
    /// After `/`: a path component's start.
    static let separator: Int8 = 9
    /// The candidate's start, or after a delimiter (`_ - . :` space, …).
    static let boundary: Int8 = 8
    /// A camelCase hump, a letter→digit step, the last capital of an acronym.
    static let camel: Int8 = 7
    static let consecutive: Int8 = 4
    static let unreachable = Int32.min / 2

    /// `query` against `candidate`: nil when it is not a subsequence;
    /// `matched` = UTF-16 offsets into `candidate`. An empty query matches
    /// with score 0.
    package static func score(query: String, candidate: String) -> (score: Int, matched: [Int])? {
        var corpus = FuzzyCorpus()
        let slot = corpus.append(candidate, tag: 1)
        return FuzzyMatcher(query: query).fuzzyMatch(corpus, slot: slot)
    }

    static func foldASCII(_ unit: UInt16) -> UInt16 {
        (0x41 ... 0x5A).contains(unit) ? unit + 0x20 : unit
    }

    /// A bit per (folded) unit class: a candidate lacking any bit of the
    /// query's mask cannot match it.
    static func maskBit(_ folded: UInt16) -> UInt64 {
        switch folded {
        case 0x61 ... 0x7A: 1 << UInt64(folded - 0x61)
        case 0x30 ... 0x39: 1 << UInt64(26 + folded - 0x30)
        default: 1 << UInt64(36 + folded % 28)
        }
    }

    private enum UnitClass {
        case lower, upper, digit, otherLetter, separator, delimiter
    }

    private static func classify(_ unit: UInt16) -> UnitClass {
        switch unit {
        case 0x61 ... 0x7A: .lower
        case 0x41 ... 0x5A: .upper
        case 0x30 ... 0x39: .digit
        case 0x2F, 0x5C: .separator
        case 0x80...: .otherLetter
        default: .delimiter
        }
    }

    static func bonuses(_ units: [UInt16]) -> [Int8] {
        var out = [Int8](repeating: 0, count: units.count)
        var prev = UnitClass.delimiter
        for (j, unit) in units.enumerated() {
            let cur = classify(unit)
            let next = j + 1 < units.count ? classify(units[j + 1]) : .delimiter
            out[j] = bonus(prev: prev, cur: cur, next: next, isFirst: j == 0)
            prev = cur
        }
        return out
    }

    private static func bonus(prev: UnitClass, cur: UnitClass, next: UnitClass, isFirst: Bool) -> Int8 {
        switch (prev, cur) {
        case (_, .separator), (_, .delimiter): 0
        case _ where isFirst: boundary
        case (.separator, _): separator
        case (.delimiter, _): boundary
        case (.lower, .upper), (.lower, .digit), (.upper, .digit), (.otherLetter, .digit): camel
        case (.upper, .upper) where next == .lower: camel
        default: 0
        }
    }
}

/// Many candidates in flat buffers — an index keeps one, so a keystroke
/// scans contiguous memory instead of thousands of small arrays. A slot is
/// appended once and killed when its text is gone (the space comes back on
/// `compacted`). `tag` is the caller's kind of slot, filtered on in `scan`.
package struct FuzzyCorpus {
    struct Slot {
        let start: Int
        let length: Int
        let mask: UInt64
        let tag: UInt8
        var alive: Bool
    }

    private(set) var units: [UInt16] = []
    private(set) var folded: [UInt16] = []
    private(set) var bonus: [Int8] = []
    private(set) var slots: [Slot] = []
    package private(set) var deadCount = 0

    package init() {}

    package var slotCount: Int { slots.count }

    package mutating func append(_ text: String, tag: UInt8) -> Int {
        let textUnits = Array(text.utf16)
        let textFolded = textUnits.map(FuzzyMatch.foldASCII)
        let mask = textFolded.reduce(UInt64(0)) { $0 | FuzzyMatch.maskBit($1) }
        slots.append(Slot(start: units.count, length: textUnits.count, mask: mask, tag: tag, alive: true))
        units += textUnits
        folded += textFolded
        bonus += FuzzyMatch.bonuses(textUnits)
        return slots.count - 1
    }

    package mutating func kill(_ slot: Int) {
        guard slots[slot].alive else { return }
        slots[slot].alive = false
        deadCount += 1
    }
}

/// One live slot `scan` matched.
package struct FuzzyHit: Equatable, Sendable {
    package let slot: Int
    package let score: Int
}

/// A query prepared once per keystroke, with the scratch rows its
/// alignments reuse (one matcher per query, never shared between threads).
package struct FuzzyMatcher {
    let needle: [UInt16]
    /// Smart case: an upper-case letter in the query makes it exact.
    let caseSensitive: Bool
    private let mask: UInt64
    private let scratch = FuzzyScratch()

    package init(query: String) {
        caseSensitive = query.contains { $0.isUppercase }
        let units = Array(query.utf16)
        needle = caseSensitive ? units : units.map(FuzzyMatch.foldASCII)
        mask = units.reduce(UInt64(0)) { $0 | FuzzyMatch.maskBit(FuzzyMatch.foldASCII($1)) }
    }

    package var isEmpty: Bool { needle.isEmpty }

    /// Every live slot whose tag is in `tags` that the query matches, with
    /// its score, in slot order. An empty query matches nothing here.
    package func scan(_ corpus: FuzzyCorpus, tags: UInt8) -> [FuzzyHit] {
        let m = needle.count
        guard m > 0 else { return [] }
        var hits: [FuzzyHit] = []
        corpus.withBuffers(caseSensitive: caseSensitive) { slots, hay, bonus in
            needle.withUnsafeBufferPointer { q in
                guard let q = q.baseAddress, let hay = hay.baseAddress, let bonus = bonus.baseAddress else { return }
                let kernel = FuzzyKernel(q: q, m: m, scratch: scratch)
                // Plain while loops: this is the per-keystroke loop, and a
                // debug build runs generic ranges and iterators unspecialized.
                var index = 0
                while index < slots.count {
                    let slot = slots[index]
                    if slot.alive, slot.tag & tags != 0, slot.mask & mask == mask, slot.length >= m,
                       let score = kernel.align(hay + slot.start, bonus + slot.start, n: slot.length, trace: false) {
                        hits.append(FuzzyHit(slot: index, score: score))
                    }
                    index += 1
                }
            }
        }
        return hits
    }

    /// One slot's score and the UTF-16 offsets of its matched units, for
    /// the rows actually shown. An empty query matches with score 0.
    package func fuzzyMatch(_ corpus: FuzzyCorpus, slot index: Int) -> (score: Int, matched: [Int])? {
        let m = needle.count
        guard m > 0 else { return (0, []) }
        let slot = corpus.slots[index]
        guard slot.length >= m else { return nil }
        return corpus.withBuffers(caseSensitive: caseSensitive) { _, hay, bonus in
            needle.withUnsafeBufferPointer { q -> (score: Int, matched: [Int])? in
                guard let q = q.baseAddress, let hay = hay.baseAddress, let bonus = bonus.baseAddress else { return nil }
                let kernel = FuzzyKernel(q: q, m: m, scratch: scratch)
                guard let score = kernel.align(hay + slot.start, bonus + slot.start, n: slot.length, trace: true) else { return nil }
                return (score, kernel.matched(n: slot.length))
            }
        }
    }
}

extension FuzzyCorpus {
    func withBuffers<T>(
        caseSensitive: Bool,
        _ body: (UnsafeBufferPointer<Slot>, UnsafeBufferPointer<UInt16>, UnsafeBufferPointer<Int8>) -> T
    ) -> T {
        slots.withUnsafeBufferPointer { slotBuffer in
            (caseSensitive ? units : folded).withUnsafeBufferPointer { hay in
                bonus.withUnsafeBufferPointer { bonusBuffer in body(slotBuffer, hay, bonusBuffer) }
            }
        }
    }
}

/// The rows one alignment works in, kept across candidates.
final class FuzzyScratch {
    private(set) var prevScore = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private(set) var curScore = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private(set) var prevRun = UnsafeMutablePointer<Int8>.allocate(capacity: 1)
    private(set) var curRun = UnsafeMutablePointer<Int8>.allocate(capacity: 1)
    private(set) var from = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Each query unit's earliest and latest possible position.
    private(set) var lo = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private(set) var hi = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// Where the last traced alignment ended.
    var end = 0
    private var rowCapacity = 1
    private var cellCapacity = 1
    private var queryCapacity = 1

    func reserve(m: Int, n: Int, trace: Bool) {
        if n > rowCapacity {
            rowCapacity = max(n, rowCapacity * 2)
            prevScore.deallocate()
            curScore.deallocate()
            prevRun.deallocate()
            curRun.deallocate()
            prevScore = .allocate(capacity: rowCapacity)
            curScore = .allocate(capacity: rowCapacity)
            prevRun = .allocate(capacity: rowCapacity)
            curRun = .allocate(capacity: rowCapacity)
        }
        if m > queryCapacity {
            queryCapacity = m
            lo.deallocate()
            hi.deallocate()
            lo = .allocate(capacity: m)
            hi = .allocate(capacity: m)
        }
        if trace, m * n > cellCapacity {
            cellCapacity = max(m * n, cellCapacity * 2)
            from.deallocate()
            from = .allocate(capacity: cellCapacity)
        }
    }

    /// The row just computed becomes the previous one.
    func swapRows() {
        swap(&prevScore, &curScore)
        swap(&prevRun, &curRun)
    }

    deinit {
        prevScore.deallocate()
        curScore.deallocate()
        prevRun.deallocate()
        curRun.deallocate()
        from.deallocate()
        lo.deallocate()
        hi.deallocate()
    }
}

/// Smith-Waterman-style alignment (fzf's v2 scheme, simplified): each
/// matched unit scores `match` plus its position bonus (doubled for the
/// first), a gap costs `gapStart` then `gapExtension` per unit, and a
/// consecutive run carries its first unit's bonus (at least `consecutive`).
/// Longer candidates lose a little, so an exact name beats a longer one.
/// Row `i` only spans the positions query unit `i` can take (between its
/// greedy forward and backward placements).
///
/// Raw pointers and while loops throughout: it runs once per candidate per
/// keystroke, and must stay fast in a debug build too (spec §7's 50 ms).
private struct FuzzyKernel {
    let q: UnsafePointer<UInt16>
    let m: Int
    let scratch: FuzzyScratch

    /// The score, or nil when the query is not a subsequence of `hay`.
    /// `trace` records the predecessors `matched` walks.
    func align(_ hay: UnsafePointer<UInt16>, _ bonus: UnsafePointer<Int8>, n: Int, trace: Bool) -> Int? {
        scratch.reserve(m: m, n: n, trace: trace)
        guard placeWindows(hay, n: n) else { return nil }
        firstRow(hay, bonus)
        var i = 1
        while i < m {
            nextRow(i, hay, bonus, n: n, trace: trace)
            scratch.swapRows()
            i += 1
        }
        let last = scratch.prevScore
        var top = FuzzyMatch.unreachable, end = -1
        var j = scratch.lo[m - 1]
        let stop = scratch.hi[m - 1]
        while j <= stop {
            if last[j] > top {
                top = last[j]
                end = j
            }
            j += 1
        }
        guard end >= 0 else { return nil }
        scratch.end = end
        let extra = n - m
        return Int(top) - (extra < 32 ? extra : 32) / 4
    }

    /// After a traced `align`: the matched offsets.
    func matched(n: Int) -> [Int] {
        var out = [Int](repeating: 0, count: m)
        var j = scratch.end
        var i = m - 1
        while i >= 0 {
            out[i] = j
            if i > 0 { j = Int(scratch.from[i * n + j]) }
            i -= 1
        }
        return out
    }

    /// false when the query is not a subsequence.
    private func placeWindows(_ hay: UnsafePointer<UInt16>, n: Int) -> Bool {
        let lo = scratch.lo, hi = scratch.hi
        var j = 0, i = 0
        while i < m {
            while j < n, hay[j] != q[i] { j += 1 }
            if j == n { return false }
            lo[i] = j
            j += 1
            i += 1
        }
        j = n - 1
        i = m - 1
        while i >= 0 {
            while hay[j] != q[i] { j -= 1 }
            hi[i] = j
            j -= 1
            i -= 1
        }
        return true
    }

    private func firstRow(_ hay: UnsafePointer<UInt16>, _ bonus: UnsafePointer<Int8>) {
        let first = q[0], score = scratch.prevScore, run = scratch.prevRun
        var j = scratch.lo[0]
        let stop = scratch.hi[0]
        while j <= stop {
            if hay[j] == first {
                score[j] = FuzzyMatch.match + Int32(bonus[j]) * FuzzyMatch.firstMultiplier
                run[j] = bonus[j]
            } else {
                score[j] = FuzzyMatch.unreachable
            }
            j += 1
        }
    }

    /// Row `i`: the best score with q[i] matched at each position of its
    /// window. `gap` is the best previous-row score ending two or more
    /// units back, less its gap penalty.
    private func nextRow(_ i: Int, _ hay: UnsafePointer<UInt16>, _ bonus: UnsafePointer<Int8>, n: Int, trace: Bool) {
        let unit = q[i], unreachable = FuzzyMatch.unreachable
        let prev = scratch.prevScore, prevRun = scratch.prevRun, cur = scratch.curScore, curRun = scratch.curRun
        let from = scratch.from
        let pLo = scratch.lo[i - 1], pHi = scratch.hi[i - 1], first = scratch.lo[i], stop = scratch.hi[i]
        var gap = unreachable, gapFrom: Int32 = -1
        var k = pLo
        while k <= pHi, k <= first - 2 {
            let value = prev[k] - FuzzyMatch.gapStart - Int32(first - 2 - k) * FuzzyMatch.gapExtension
            if prev[k] > unreachable, value > gap {
                gap = value
                gapFrom = Int32(k)
            }
            k += 1
        }
        var j = first
        while j <= stop {
            let diagonal = j - 1 >= pLo && j - 1 <= pHi ? prev[j - 1] : unreachable
            if hay[j] == unit {
                let own = bonus[j]
                var top = unreachable, run = own, pred: Int32 = -1
                if diagonal > unreachable {
                    let start = own >= FuzzyMatch.boundary && own > prevRun[j - 1] ? own : prevRun[j - 1]
                    var carried = own > start ? own : start
                    if carried < FuzzyMatch.consecutive { carried = FuzzyMatch.consecutive }
                    top = diagonal + FuzzyMatch.match + Int32(carried)
                    run = start
                    pred = Int32(j - 1)
                }
                if gap > unreachable, gap + FuzzyMatch.match + Int32(own) > top {
                    top = gap + FuzzyMatch.match + Int32(own)
                    run = own
                    pred = gapFrom
                }
                cur[j] = top
                curRun[j] = run
                if trace { from[i * n + j] = pred }
            } else {
                cur[j] = unreachable
            }
            if gap > unreachable { gap -= FuzzyMatch.gapExtension }
            if diagonal > unreachable, diagonal - FuzzyMatch.gapStart > gap {
                gap = diagonal - FuzzyMatch.gapStart
                gapFrom = Int32(j - 1)
            }
            j += 1
        }
    }
}
