import XCTest
import WatchtowerTestSupport

final class SyntheticAudioTests: XCTestCase {
    func testZerosAreExactZeros() {
        let samples = SyntheticAudio.zeros(seconds: 1.5)
        XCTAssertEqual(samples.count, 24_000)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    func testNoiseAndHumHitTheTargetLevelWithinOneDB() {
        let cases: [(String, [Float], Double)] = [
            ("white -60", SyntheticAudio.whiteNoise(seconds: 2, dBFS: -60, seed: 1), -60),
            ("white -45", SyntheticAudio.whiteNoise(seconds: 2, dBFS: -45, seed: 2), -45),
            ("pink -60", SyntheticAudio.pinkNoise(seconds: 2, dBFS: -60, seed: 3), -60),
            ("pink -45", SyntheticAudio.pinkNoise(seconds: 2, dBFS: -45, seed: 4), -45),
            ("hum -40", SyntheticAudio.hum(seconds: 2, dBFS: -40), -40)
        ]
        for (name, samples, target) in cases {
            XCTAssertEqual(SyntheticAudio.dBFS(samples), target, accuracy: 1, name)
        }
    }

    func testFadeEndsAtTheDitherLevel() {
        let samples = SyntheticAudio.fadeToDither(seconds: 10, fadeSec: 3, seed: 5)
        XCTAssertEqual(SyntheticAudio.dBFS(Array(samples[0..<160])), -45, accuracy: 1.5)
        XCTAssertEqual(SyntheticAudio.dBFS(Array(samples[64_000...])), -90, accuracy: 1)
    }

    func testSameSeedGivesSameSamplesAndOtherSeedsDiffer() {
        XCTAssertEqual(SyntheticAudio.whiteNoise(seconds: 0.5, dBFS: -45, seed: 7),
                       SyntheticAudio.whiteNoise(seconds: 0.5, dBFS: -45, seed: 7))
        XCTAssertEqual(SyntheticAudio.pinkNoise(seconds: 0.5, dBFS: -45, seed: 7),
                       SyntheticAudio.pinkNoise(seconds: 0.5, dBFS: -45, seed: 7))
        XCTAssertEqual(SyntheticAudio.fadeToDither(seconds: 0.5, seed: 7),
                       SyntheticAudio.fadeToDither(seconds: 0.5, seed: 7))
        XCTAssertNotEqual(SyntheticAudio.whiteNoise(seconds: 0.5, dBFS: -45, seed: 7),
                          SyntheticAudio.whiteNoise(seconds: 0.5, dBFS: -45, seed: 8))
    }

    func testComposeTimelineOffsetsAreExact() {
        let speechA = [Float](repeating: 0.1, count: 8_000)
        let speechB = [Float](repeating: 0.2, count: 4_000)
        let composition = SyntheticAudio.compose([
            .speech(speechA, reference: "one two"),
            .filler(SyntheticAudio.zeros(seconds: 60)),
            .speech(speechB, reference: "three")
        ])

        XCTAssertEqual(composition.samples.count, 8_000 + 960_000 + 4_000)
        XCTAssertEqual(composition.timeline.map(\.kind), [.speech, .filler, .speech])
        XCTAssertEqual(composition.timeline.map(\.range), [0..<8_000, 8_000..<968_000, 968_000..<972_000])
        XCTAssertEqual(composition.timeline.map(\.reference), ["one two", nil, "three"])
        XCTAssertEqual(composition.fillerSeconds, [0.5...60.5])
        XCTAssertEqual(composition.reference, "one two three")
        XCTAssertEqual(Array(composition.samples[968_000..<972_000]), speechB)
    }
}
