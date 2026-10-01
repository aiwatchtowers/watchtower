import XCTest
import ViewInspector
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// `VoiceCardView` — header/reason text, clip playback buttons, the
/// candidate picker's pre-selection, and the four dispositions.
@MainActor
final class VoiceCardViewTests: XCTestCase {
    func testCardShowsReasonClipsAndPreselectedSuggestion() throws {
        let card = VoiceCard.fixture(
            reason: .unsure,
            suggestion: VoicePrint(id: 1, personKey: "alice@example.com", displayName: "Alice"),
            score: 0.66,
            clips: [ClipSpan(start: 1, end: 6), ClipSpan(start: 9, end: 14)])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })

        XCTAssertNoThrow(try view.inspect().find(text: "Looks like Alice (0.66)"))
        XCTAssertEqual(
            try view.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string().hasPrefix("▶") }.count,
            2)
        XCTAssertEqual(try view.inspect().find(ViewType.Picker.self).selectedValue(PersonChoice.self).displayName, "Alice")
    }

    /// A strong score that still landed in the unsure band (the matched
    /// person wasn't invited) gets the caveat appended.
    func testUnsureHighScoreAddsNotInvitedCaveat() throws {
        let card = VoiceCard.fixture(
            reason: .unsure,
            suggestion: VoicePrint(id: 2, personKey: "bob@example.com", displayName: "Bob"),
            score: 0.82,
            clips: [ClipSpan(start: 0, end: 3)])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })

        XCTAssertNoThrow(try view.inspect().find(text: "Looks like Bob (0.82) … but Bob was not invited"))
    }

    func testUnknownReasonReadsNotRecognized() throws {
        let card = VoiceCard.fixture(reason: .unknown, clips: [])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertNoThrow(try view.inspect().find(text: "Not recognized"))
    }

    func testImportConfirmReasonNamesTheSuggestion() throws {
        let card = VoiceCard.fixture(
            reason: .importConfirm,
            suggestion: VoicePrint(id: 3, personKey: "carol@example.com", displayName: "Carol"),
            clips: [])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertNoThrow(try view.inspect().find(text: "From an imported file: is this Carol?"))
    }

    func testConflictAndRelabelReasons() throws {
        let conflict = VoiceCardView(
            card: .fixture(reason: .conflict, clips: []), onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertNoThrow(try conflict.inspect().find(text: "Two sources disagree"))

        let relabel = VoiceCardView(
            card: .fixture(reason: .relabel, clips: []), onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertNoThrow(try relabel.inspect().find(text: "Relabel this voice"))
    }

    /// No suggestion (or no candidate matching it) preselects "New person…",
    /// so a fresh face never gets silently mapped onto an unrelated row.
    func testNoMatchingSuggestionPreselectsNewPerson() throws {
        let card = VoiceCard.fixture(reason: .unknown, suggestion: nil, clips: [])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertEqual(try view.inspect().find(ViewType.Picker.self).selectedValue(PersonChoice.self).displayName, "New person…")
    }

    func testTappingAClipButtonInvokesOnPlayWithThatSpan() throws {
        var played: [ClipSpan] = []
        let clips = [ClipSpan(start: 1, end: 6), ClipSpan(start: 9, end: 14)]
        let card = VoiceCard.fixture(reason: .unknown, clips: clips)
        let view = VoiceCardView(card: card, onPlay: { played.append($0) }, onConfirm: { _ in }, onDismiss: { _ in })

        let buttons = try view.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string().hasPrefix("▶") }
        try buttons[1].tap()
        XCTAssertEqual(played, [clips[1]])
    }

    /// The button shows the clip's length (a start timecode read as a
    /// duration), and the clip that is playing turns into its Stop.
    func testClipButtonShowsLengthAndPlayingClipShowsStop() throws {
        let clips = [ClipSpan(start: 520, end: 526), ClipSpan(start: 580, end: 584.6)]
        let card = VoiceCard.fixture(reason: .unknown, clips: clips)
        let view = VoiceCardView(
            card: card, isPlaying: { $0 == clips[1] }, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })

        XCTAssertNoThrow(try view.inspect().find(button: "▶ 6 s"))
        XCTAssertNoThrow(try view.inspect().find(button: "■ Stop"))
        XCTAssertNoThrow(try view.inspect().find(text: "at 8:40"))
    }

    /// Picking a name is not a save: while Confirm is possible the card
    /// says so; with nothing confirmable (an empty "New person…") it doesn't.
    func testUnsavedHintShowsOnlyWhileConfirmIsPossible() throws {
        let suggested = VoiceCard.fixture(
            reason: .unsure, suggestion: VoicePrint(id: 1, personKey: "alice@example.com", displayName: "Alice"),
            score: 0.6, clips: [])
        let blank = VoiceCard.fixture(reason: .unknown, clips: [])

        XCTAssertNoThrow(try VoiceCardView(card: suggested, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
            .inspect().find(text: "Not saved until you press Confirm"))
        XCTAssertThrowsError(try VoiceCardView(card: blank, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
            .inspect().find(text: "Not saved until you press Confirm"))
    }

    /// The owner's own registry row reads as "Me", never as a colleague.
    func testOwnerCandidateReadsAsMe() throws {
        let owner = PersonChoice(personKey: "me@example.com", displayName: "Owner", inRegistry: true, isOwner: true)
        let card = VoiceCard.fixture(reason: .unknown, clips: [], candidates: [owner])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertNoThrow(try view.inspect().find(text: "Me (Owner)"))
        XCTAssertNoThrow(try view.inspect().find(text: "In this meeting"))
    }

    /// Confirm with the (pre-selected, suggestion-matched) candidate sends
    /// that exact candidate back — no "new person" fields involved.
    func testConfirmSendsTheSelectedCandidate() throws {
        let card = VoiceCard.fixture(
            reason: .unknown,
            suggestion: VoicePrint(id: 9, personKey: "alice@example.com", displayName: "Alice"),
            clips: [])
        var confirmed: PersonChoice?
        let view = VoiceCardView(
            card: card, onPlay: { _ in }, onConfirm: { confirmed = $0 }, onDismiss: { _ in })

        try view.inspect().find(button: "Confirm").tap()
        XCTAssertEqual(confirmed?.personKey, "alice@example.com")
        XCTAssertEqual(confirmed?.displayName, "Alice")
    }

    /// Spec §3.1's keys belong to ONE card: only the active card carries
    /// Enter (confirm) and space (play), so a keypress can never confirm an
    /// arbitrary card in the list.
    func testOnlyTheActiveCardCarriesKeyboardShortcuts() throws {
        let card = VoiceCard.fixture(
            reason: .unknown,
            suggestion: VoicePrint(id: 9, personKey: "alice@example.com", displayName: "Alice"),
            clips: [ClipSpan(start: 1, end: 6)])
        func shortcuts(_ view: VoiceCardView) throws -> [KeyboardShortcut?] {
            let inspected = try view.inspect()
            let play = try inspected.find(ViewType.Button.self) { try $0.labelView().text().string().hasPrefix("▶") }
            return try [inspected.find(button: "Confirm"), play].map {
                try $0.modifier(VoiceCardShortcut.self).actualView().shortcut
            }
        }
        let active = try shortcuts(VoiceCardView(card: card, isActive: true, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in }))
        XCTAssertEqual(Set(active.compactMap { $0 }), [.defaultAction, KeyboardShortcut(.space)])

        let inactive = try shortcuts(VoiceCardView(card: card, isActive: false, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in }))
        XCTAssertEqual(inactive.count, 2, "both controls are still found")
        XCTAssertTrue(inactive.allSatisfy { $0 == nil }, "an inactive card never answers Enter or space")
    }

    func testDismissButtonsSendTheirKind() throws {
        var kinds: [DismissKind] = []
        let card = VoiceCard.fixture(reason: .unknown, clips: [])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { kinds.append($0) })

        try view.inspect().find(button: "Don't know").tap()
        try view.inspect().find(button: "Several people").tap()
        try view.inspect().find(button: "Skip").tap()

        XCTAssertEqual(kinds, [.dontKnow, .severalPeople, .skip])
    }
}

extension VoiceCard {
    /// Test-only builder — every field defaulted except the ones a given
    /// test cares about.
    static func fixture(
        id: Int64 = 1,
        transcriptID: Int64 = 1,
        meetingTitle: String = "Weekly sync",
        date: String = "2026-09-28T10:00:00Z",
        clusterLabel: String = "Speaker 2",
        reason: VoiceLabelReason,
        suggestion: VoicePrint? = nil,
        score: Float? = nil,
        clips: [ClipSpan],
        audioPath: String = "/tmp/rec.caf",
        candidates: [PersonChoice] = []
    ) -> VoiceCard {
        let resolvedCandidates: [PersonChoice]
        if candidates.isEmpty, let suggestion {
            resolvedCandidates = [PersonChoice(personKey: suggestion.personKey, displayName: suggestion.displayName, inRegistry: true)]
        } else {
            resolvedCandidates = candidates
        }
        return VoiceRegistryCenter.VoiceCard(
            id: id, transcriptID: transcriptID, meetingTitle: meetingTitle, date: date,
            clusterLabel: clusterLabel, reason: reason, suggestion: suggestion, score: score,
            clips: clips, clipTexts: clips.map { _ in "" }, audioPath: audioPath,
            candidateGroups: resolvedCandidates.isEmpty ? [] : [CandidateGroup(title: "In this meeting", choices: resolvedCandidates)])
    }
}
