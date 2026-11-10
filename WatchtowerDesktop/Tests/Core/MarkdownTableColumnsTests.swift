import Foundation
import Testing
@testable import WatchtowerCore

/// A chat table's column widths (ask #1197, target #1714): natural when it
/// fits, otherwise the column's width with the wide columns wrapping.
@Suite("MarkdownTableColumns")
struct MarkdownTableColumnsTests {
    private func widths(_ natural: [CGFloat], _ minimum: [CGFloat], _ available: CGFloat) -> [CGFloat] {
        MarkdownTableColumns.widths(natural: natural, minimum: minimum, available: available)
    }

    @Test func aTableThatFitsKeepsItsNaturalWidths() {
        #expect(widths([40, 120.3, 60], [30, 50, 40], 400) == [40, 121, 60])
        #expect(widths([40, 120], [30, 50], 160) == [40, 120], "exactly the width fits")
    }

    @Test func noLimitMeansNaturalWidths() {
        for available in [CGFloat.infinity, 0, -10, .nan] {
            #expect(widths([40, 900], [30, 60], available) == [40, 900])
        }
    }

    @Test func oneWideColumnAbsorbsTheShrink() {
        // "Пункт | Что сказано": the short column keeps its line.
        let result = widths([70, 1200], [60, 90], 400)
        #expect(result == [70, 330])
        #expect(result.reduce(0, +) <= 400)
    }

    @Test func twoWideColumnsShareByNaturalWidth() {
        let result = widths([50, 600, 300], [40, 80, 80], 410)
        #expect(result[0] == 50, "a column within its fair share keeps its width")
        #expect(result[1] == 240)
        #expect(result[2] == 120)
        #expect(result.reduce(0, +) <= 410)
    }

    @Test func aWideColumnNeverFallsUnderItsMinimum() {
        // Split by natural width the second column would get 20.
        let result = widths([1000, 60, 1000], [80, 60, 80], 300)
        #expect(result[1] >= 60)
        #expect(result.reduce(0, +) <= 300)
        let lopsided = widths([2000, 120], [60, 110], 300)
        #expect(lopsided[1] == 120, "within its fair share")
        #expect(lopsided == [180, 120])
        let floored = widths([3000, 200], [60, 150], 220)
        #expect(floored[1] >= 150, "keeps its minimum rather than its share")
        #expect(floored.reduce(0, +) <= 220)
    }

    @Test func minimumsThatDoNotFitScaleDownTogether() {
        let result = widths([300, 300, 300], [100, 100, 100], 150)
        #expect(result == [50, 50, 50])
    }

    @Test func narrowColumnsGiveWayWhenTheWideOnesNeedTheirMinimums() {
        // The narrow columns keep their natural width by the fair share,
        // leaving the wide one less than its minimum: everyone shrinks.
        let result = widths([90, 90, 1000], [20, 20, 200], 300)
        #expect(result.reduce(0, +) <= 300)
        #expect(result[2] >= 200)
        #expect(result[0] >= 20 && result[1] >= 20)
    }

    @Test func totalNeverExceedsTheWidth() {
        let cases: [([CGFloat], [CGFloat])] = [
            ([10, 20, 30, 4000, 50], [10, 20, 30, 96, 50]),
            ([500, 500], [96, 96]),
            ([1, 2000, 2000, 2000], [1, 96, 96, 96]),
            ([33.3, 77.7, 1234.5], [20.2, 40.4, 96])
        ]
        for (natural, minimum) in cases {
            for available: CGFloat in [40, 150, 333, 640] {
                let result = widths(natural, minimum, available)
                #expect(result.count == natural.count)
                #expect(result.reduce(0, +) <= available, "\(natural) at \(available)")
                #expect(result.allSatisfy { $0 >= 0 && $0 == $0.rounded() })
            }
        }
    }
}
