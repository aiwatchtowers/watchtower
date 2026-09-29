import XCTest
import ViewInspector
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// `RecordingTranscriptTab` after the voice-registry rewrite: speaker labels
/// open the Voices window instead of an in-transcript rename sheet, and the
/// LLM "Suggest speaker names" affordance is gone entirely (its Go CLI no
/// longer exists) in favor of the recap-refresh hint.
@MainActor
final class RecordingTranscriptTabTests: XCTestCase {
    private static let utterances = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 5, speaker: "Я", text: "hello"),
        TranscriptUtterance(idx: 1, startSec: 5, endSec: 10, speaker: "Speaker 2", text: "hi there")
    ]

    private func makeTab(
        showRecapRefreshHint: Bool = false,
        onListenToSamples: @escaping (String) -> Void = { _ in },
        onRegenerateRecap: @escaping () -> Void = {}
    ) -> RecordingTranscriptTab {
        RecordingTranscriptTab(
            transcriptText: "hello hi there",
            utterances: Self.utterances,
            scrollTarget: .constant(nil),
            showRecapRefreshHint: showRecapRefreshHint,
            onSetUtteranceDeleted: { _, _ in true },
            onListenToSamples: onListenToSamples,
            onRegenerateRecap: onRegenerateRecap
        )
    }

    func testTappingASpeakerLabelCallsOnListenToSamples() throws {
        var listened: String?
        // `onListenToSamples` isn't `makeTab`'s last parameter, so trailing-closure form would bind wrong.
        // swiftlint:disable:next trailing_closure
        let view = makeTab(onListenToSamples: { listened = $0 })
        try view.inspect().find(button: "Speaker 2").tap()
        XCTAssertEqual(listened, "Speaker 2")
    }

    /// «Я» is the owner's own cluster — a plain label, never a button.
    func testOwnerLabelIsNotTappable() throws {
        let view = makeTab()
        XCTAssertThrowsError(try view.inspect().find(button: "Я"))
    }

    /// The LLM guess UI is fully retired — its Go CLI (`speaker-guess`) no
    /// longer exists.
    func testNoSuggestSpeakerNamesButtonExists() throws {
        let view = makeTab()
        XCTAssertThrowsError(try view.inspect().find(button: "Suggest speaker names"))
    }

    func testRecapHintVisibleOnlyWhenFlagged() throws {
        let hidden = makeTab(showRecapRefreshHint: false)
        XCTAssertThrowsError(try hidden.inspect().find(text: "Speaker names were updated — regenerate the recap?"))

        let shown = makeTab(showRecapRefreshHint: true)
        XCTAssertNoThrow(try shown.inspect().find(text: "Speaker names were updated — regenerate the recap?"))
    }

    func testRegenerateButtonFiresOnRegenerateRecap() throws {
        var regenerated = false
        // `onRegenerateRecap` isn't `makeTab`'s last parameter, so trailing-closure form would bind wrong.
        // swiftlint:disable:next trailing_closure
        let view = makeTab(showRecapRefreshHint: true, onRegenerateRecap: { regenerated = true })
        try view.inspect().find(button: "Regenerate").tap()
        XCTAssertTrue(regenerated)
    }
}
