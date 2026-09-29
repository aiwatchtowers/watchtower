import SwiftUI
import WatchtowerCore

/// A keyboard shortcut that only the ACTIVE Voices card carries (spec §3.1:
/// space = play, Enter = confirm on one card at a time) — nil on every other
/// card. A named modifier rather than a bare `.keyboardShortcut` so tests can
/// find it and read which shortcut, if any, a control got.
struct VoiceCardShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        content.keyboardShortcut(shortcut)
    }
}

/// One playable clip: a "▶ 0:07"-style button plus its transcript snippet.
/// Pure/stateless — shared by the Queue's `VoiceCardView` and the Train
/// screen (`VoiceTrainView`), both of which just supply what to play and
/// what to show.
struct VoiceClipRow: View {
    let clip: ClipSpan
    let text: String
    /// The first clip of the ACTIVE card gets the space-bar shortcut — the
    /// common case of "hear the one sample and decide".
    let isFirst: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onPlay) {
                Text("▶ \(TranscriptFormatting.formatTimecode(clip.start))")
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .modifier(VoiceCardShortcut(shortcut: isFirst ? KeyboardShortcut(.space) : nil))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Shared "who is this?" picker (spec §3.1): a picker over known candidates
/// plus a "New person…" sentinel that reveals name/email fields. Used by both
/// the Queue's `VoiceCardView` and the Train screen (`VoiceTrainView`) — the
/// candidate list and the caller's disposition differ, the picking UI and its
/// reserved-name guard don't.
struct VoicePersonPicker: View {
    /// Sentinel row for "type a name that isn't in either list" — keeps the
    /// picker's selection type a plain (`Hashable`) `PersonChoice` instead of
    /// an optional, so ViewInspector's `selectedValue` resolves it directly.
    static let newPersonChoice = PersonChoice(personKey: "", displayName: "New person…", inRegistry: false)

    let candidates: [PersonChoice]
    @Binding var selection: PersonChoice
    @Binding var newName: String
    @Binding var newEmail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Who is this?", selection: $selection) {
                ForEach(candidates, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
                Text("New person…").tag(Self.newPersonChoice)
            }
            .labelsHidden()
            if selection == Self.newPersonChoice {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("Email (optional)", text: $newEmail)
                    .textFieldStyle(.roundedBorder)
                if SpeakerNaming.isReserved(newName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Text("«Я» and “Speaker N” are reserved names")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The candidate to confirm: the selected row as-is, or a freshly-typed
    /// one built from `newName`/`newEmail` — nil when "New person…" is
    /// selected but the name is empty or reserved (never confirmable).
    static func resolve(selection: PersonChoice, newName: String, newEmail: String) -> PersonChoice? {
        guard selection == newPersonChoice else { return selection }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !SpeakerNaming.isReserved(name) else { return nil }
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let personKey = email.isEmpty ? name.lowercased() : email.lowercased()
        return PersonChoice(personKey: personKey, displayName: name, inRegistry: false)
    }
}
