import SwiftUI
import WatchtowerCore

/// `VoiceRegistryCenter`'s nested types, spelled bare across the Voices UI —
/// the same "typealias the center's model types" convention other
/// AppState-owned centers don't need only because their model types already
/// live top-level.
typealias VoiceCard = VoiceRegistryCenter.VoiceCard
typealias PersonChoice = VoiceRegistryCenter.PersonChoice

/// One Voices-queue card: header (meeting · date · why the owner is needed,
/// spec §3.1's five reasons), a clip button + transcript snippet per playable
/// span, a candidate picker (this meeting's not-yet-known attendees first,
/// then the registry, then "New person…"), and the four dispositions
/// (Confirm / Don't know / Several people / Skip). Pure view — every write
/// goes back through the closures the Voices window wires to
/// `VoiceRegistryCenter`; this view never touches the DB.
///
/// Keyboard (spec §3.1: space = play, 1–9 = pick, Enter = confirm) lives on
/// the ACTIVE card only — the window marks the first card in the list. With
/// every card carrying Enter, one keypress would confirm an arbitrary card's
/// preselected suggestion and mint a wrong owner anchor.
struct VoiceCardView: View {
    let card: VoiceCard
    let isActive: Bool
    /// Whether a clip of this card is the one playing (drives its Stop).
    let isPlaying: (ClipSpan) -> Bool
    let onPlay: (ClipSpan) -> Void
    let onConfirm: (PersonChoice) -> Void
    let onDismiss: (DismissKind) -> Void

    @State private var selectedCandidate: PersonChoice
    @State private var newName = ""
    @State private var newEmail = ""

    init(
        card: VoiceCard,
        isActive: Bool = true,
        isPlaying: @escaping (ClipSpan) -> Bool = { _ in false },
        onPlay: @escaping (ClipSpan) -> Void,
        onConfirm: @escaping (PersonChoice) -> Void,
        onDismiss: @escaping (DismissKind) -> Void
    ) {
        self.card = card
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _selectedCandidate = State(initialValue: Self.preselect(card))
    }

    /// The suggestion pre-selects its matching candidate row when the
    /// registry match is one of this card's choices; otherwise "New person…"
    /// (an import/conflict suggestion is not always someone this meeting
    /// invited).
    private static func preselect(_ card: VoiceCard) -> PersonChoice {
        guard let suggestion = card.suggestion,
              let match = card.candidates.first(where: { $0.personKey == suggestion.personKey })
        else { return VoicePersonPicker.newPersonChoice }
        return match
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Array(card.clips.enumerated()), id: \.offset) { index, clip in
                clipRow(clip, index: index)
            }
            VoicePersonPicker(candidates: card.candidates, selection: $selectedCandidate, newName: $newName, newEmail: $newEmail)
            actions
        }
        .padding(12)
        .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        // Quick candidate selection without leaving the keyboard: 1-9 picks
        // that row of `card.candidates` (never the "New person…" sentinel —
        // it has no number). Active card only.
        .onKeyPress(characters: .init(charactersIn: "123456789")) { press in
            guard isActive, let digit = press.characters.first?.wholeNumberValue,
                  card.candidates.indices.contains(digit - 1) else { return .ignored }
            selectedCandidate = card.candidates[digit - 1]
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(card.meetingTitle).fontWeight(.semibold)
            Text("·").foregroundStyle(.secondary)
            Text(TranscriptFormatting.formattedDate(card.date)).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text(reasonText).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }

    /// Why this card needs the owner (spec §3.1's five reasons).
    private var reasonText: String {
        switch card.reason {
        case .unknown:
            return "Not recognized"
        case .unsure:
            guard let suggestion = card.suggestion, let score = card.score else { return "Not recognized" }
            let base = "Looks like \(suggestion.displayName) (\(String(format: "%.2f", score)))"
            // A strong score still lands in the unsure band when the match
            // isn't one of this meeting's invited attendees — worth saying
            // out loud rather than looking like an ordinary low-confidence
            // guess.
            return score >= 0.70 ? "\(base) … but \(suggestion.displayName) was not invited" : base
        case .importConfirm:
            guard let suggestion = card.suggestion else { return "From an imported file" }
            return "From an imported file: is this \(suggestion.displayName)?"
        case .conflict:
            return "Two sources disagree"
        case .relabel:
            return "Relabel this voice"
        }
    }

    private func clipRow(_ clip: ClipSpan, index: Int) -> some View {
        VoiceClipRow(
            clip: clip, text: card.clipTexts.indices.contains(index) ? card.clipTexts[index] : "",
            isFirst: isActive && index == 0, isPlaying: isPlaying(clip)) { onPlay(clip) }
    }

    private var confirmDisabled: Bool {
        VoicePersonPicker.resolve(selection: selectedCandidate, newName: newName, newEmail: newEmail) == nil
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Confirm") { confirm() }
                .buttonStyle(.borderedProminent)
                .modifier(VoiceCardShortcut(shortcut: isActive ? .defaultAction : nil))
                .disabled(confirmDisabled)
            Button("Don't know") { onDismiss(.dontKnow) }
            Button("Several people") { onDismiss(.severalPeople) }
            Spacer()
            Button("Skip") { onDismiss(.skip) }
        }
        .controlSize(.small)
    }

    private func confirm() {
        guard let resolved = VoicePersonPicker.resolve(selection: selectedCandidate, newName: newName, newEmail: newEmail) else { return }
        onConfirm(resolved)
    }
}
