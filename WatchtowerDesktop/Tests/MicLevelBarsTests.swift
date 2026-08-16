import XCTest
@testable import WatchtowerDesktop

/// `MicLevelBars.displayFraction` is the pure normalization behind the
/// capsule's level bars — testable without rendering.
final class MicLevelBarsTests: XCTestCase {

    func test_displayFractionZero_isZero() {
        XCTAssertEqual(MicLevelBars.displayFraction(0), 0)
    }

    func test_displayFractionNegative_isZero() {
        XCTAssertEqual(MicLevelBars.displayFraction(-1), 0)
    }

    func test_displayFractionAtReferenceRMS_isFull() {
        XCTAssertEqual(MicLevelBars.displayFraction(0.15), 1.0, accuracy: 0.001)
    }

    func test_displayFractionAtQuarterReference_isHalf() {
        // sqrt(0.0375 / 0.15) = sqrt(0.25) = 0.5
        XCTAssertEqual(MicLevelBars.displayFraction(0.0375), 0.5, accuracy: 0.001)
    }

    func test_displayFraction_monotonicNonDecreasing() {
        let inputs: [Float] = [0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.15, 0.3]
        let fractions = inputs.map { MicLevelBars.displayFraction($0) }
        for (previous, next) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next,
                                     "displayFraction must be monotonic non-decreasing over \(inputs)")
        }
    }
}
