import Foundation

/// A chat table's column widths for the width it has (ask #1197, target
/// #1714): one rule for the finished answer's native table and the
/// streaming answer's grid. A table that fits keeps every column at its
/// natural width (one line per cell). A wider one fills the width and
/// never scrolls: a column whose natural width is within its fair share of
/// what is left keeps it, and the remaining width goes to the wide
/// columns — in proportion to their natural widths, never under their
/// minimums — whose cells then wrap. Widths are whole points, their sum
/// never more than `available` (minimums that do not fit are scaled down
/// together, so a long word breaks by character).
public enum MarkdownTableColumns {
    /// `natural[i]`: column `i`'s widest cell on one line; `minimum[i]`:
    /// the width it keeps when it has to wrap (its longest word, capped by
    /// the caller); `available`: the columns' total, the gaps between them
    /// already taken out. A non-finite or non-positive `available` means
    /// "no limit": the natural widths.
    public static func widths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat) -> [CGFloat] {
        let natural = natural.map { max(0, ceil($0)) }
        guard available.isFinite, available > 0, natural.reduce(0, +) > available else { return natural }
        let floors = natural.indices.map { index in
            min(natural[index], ceil(max(0, index < minimum.count ? minimum[index] : 0)))
        }
        let floorTotal = floors.reduce(0, +)
        guard floorTotal < available else {
            let scale = available / floorTotal
            return floors.map { floor($0 * scale) }
        }

        // Fair share: a column narrower than an equal split of what is
        // left keeps its natural width; repeat until none does.
        var widths = [CGFloat?](repeating: nil, count: natural.count)
        while true {
            let open = widths.indices.filter { widths[$0] == nil }
            let left = available - widths.compactMap(\.self).reduce(0, +)
            let share = left / CGFloat(open.count)
            let narrow = open.filter { natural[$0] <= share }
            guard !narrow.isEmpty, narrow.count < open.count else { break }
            narrow.forEach { widths[$0] = natural[$0] }
        }
        // The wide columns split the rest by natural width; one that would
        // fall under its minimum keeps the minimum instead.
        while true {
            let open = widths.indices.filter { widths[$0] == nil }
            let left = available - widths.compactMap(\.self).reduce(0, +)
            let weight = open.reduce(CGFloat(0)) { $0 + natural[$1] }
            let short = open.filter { left * natural[$0] / weight < floors[$0] }
            guard !short.isEmpty, short.count < open.count else {
                for index in open {
                    widths[index] = short.count == open.count ? floors[index] : floor(left * natural[index] / weight)
                }
                break
            }
            short.forEach { widths[$0] = floors[$0] }
        }
        let result = widths.map { $0 ?? 0 }
        guard result.reduce(0, +) > available else { return result }
        // The narrow columns took what the wide ones' minimums need: every
        // column gets its minimum and a share of the rest by what it lacks.
        let spare = available - floorTotal
        let lack = natural.indices.reduce(CGFloat(0)) { $0 + natural[$1] - floors[$1] }
        return natural.indices.map { floors[$0] + floor(spare * (natural[$0] - floors[$0]) / lack) }
    }
}
