import SwiftUI
import WatchtowerCore

/// `VoiceRegistryCenter`'s Train-mode nested types, spelled bare — the
/// `VoiceCardView` convention.
typealias TrainGroup = VoiceRegistryCenter.TrainGroup
typealias TrainQuality = VoiceRegistryCenter.TrainQuality

/// The Voices window's Train screen (spec §4.2): bulk labeling of
/// cross-meeting voice groups, "like the research spike". A quality header
/// (named speech, estimated precision/recall on the owner's own anchors,
/// people counts), then one card per group — ordered by total speech,
/// live-regrouped after every confirm/dismiss. Pure reader + dispatcher over
/// `VoiceRegistryCenter`; this view never touches the DB.
struct VoiceTrainView: View {
    @Environment(AppState.self) private var appState
    /// View-local, not AppState-owned — the same reasoning as
    /// `VoicesWindowView.clipPlayer`.
    @State private var clipPlayer = ClipPlayer()

    private var center: VoiceRegistryCenter { appState.voiceRegistryCenter }

    var body: some View {
        if center.groups.isEmpty {
            Text("No new voices to train")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    qualityHeader
                    ForEach(center.groups) { group in
                        TrainGroupCardView(
                            group: group,
                            // Keyboard shortcuts on the first group only (the
                            // `VoiceCardView.isActive` rule).
                            isActive: group.id == center.groups.first?.id,
                            registryChoices: center.registryChoices,
                            clips: center.trainClips,
                            isPlaying: { clip, audioPath in clipPlayer.isPlaying(url: URL(fileURLWithPath: audioPath), span: clip) },
                            onPlay: { clip, audioPath in clipPlayer.toggle(url: URL(fileURLWithPath: audioPath), span: clip) },
                            onConfirm: { person in Task { await center.confirmGroup(group, person: person) } },
                            onDismiss: { severalPeople in Task { await center.dismissGroup(group, severalPeople: severalPeople) } }
                        )
                    }
                }
                .padding(12)
            }
            .modifier(ClipPlayerErrorInset(player: clipPlayer))
        }
    }

    /// Spec §4.2: named speech (total / by owner / auto); estimated
    /// precision/recall at the current threshold; people count and
    /// single-channel people. A visible precision drop suggests a review —
    /// nothing here ever moves a threshold on its own.
    private var qualityHeader: some View {
        let quality = center.quality
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(Int(quality.namedMinutes)) min named · \(Int(quality.ownerMinutes)) min by you · \(Int(quality.autoMinutes)) min auto")
                .font(.headline)
            HStack(spacing: 12) {
                if quality.precision.isFinite {
                    Text("Precision \(Int((quality.precision * 100).rounded()))%")
                }
                if quality.recall.isFinite {
                    Text("Recall \(Int((quality.recall * 100).rounded()))%")
                }
                Text("\(quality.people) people")
                if quality.singleChannelPeople > 0 {
                    Text("\(quality.singleChannelPeople) single-channel")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

/// One Train-screen group card: every audio member's clip row, a "+N
/// meetings without audio" line when the group has any, the suggested person
/// (pre-selected in the shared picker), and the three dispositions
/// (Confirm / Several people / Don't know — Train has no per-card "skip",
/// it just comes back on the next `loadTrain`).
private struct TrainGroupCardView: View {
    let group: TrainGroup
    let isActive: Bool
    let registryChoices: [PersonChoice]
    let clips: [String: VoiceRegistryCenter.TrainClip]
    /// (span, audioPath) is the clip playing — drives its Stop.
    let isPlaying: (ClipSpan, String) -> Bool
    let onPlay: (ClipSpan, String) -> Void
    let onConfirm: (PersonChoice) -> Void
    let onDismiss: (_ severalPeople: Bool) -> Void

    @State private var selectedCandidate: PersonChoice
    @State private var newName = ""
    @State private var newEmail = ""

    init(
        group: TrainGroup,
        isActive: Bool,
        registryChoices: [PersonChoice],
        clips: [String: VoiceRegistryCenter.TrainClip],
        isPlaying: @escaping (ClipSpan, String) -> Bool,
        onPlay: @escaping (ClipSpan, String) -> Void,
        onConfirm: @escaping (PersonChoice) -> Void,
        onDismiss: @escaping (_ severalPeople: Bool) -> Void
    ) {
        self.group = group
        self.isActive = isActive
        self.registryChoices = registryChoices
        self.clips = clips
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _selectedCandidate = State(initialValue: Self.preselect(group, registryChoices: registryChoices))
    }

    /// The suggestion (registry person or not-yet-registered attendee)
    /// pre-selects its matching candidate row when it's one of this card's
    /// choices; otherwise "New person…" — the `VoiceCardView` preselect rule.
    private static func preselect(_ group: TrainGroup, registryChoices: [PersonChoice]) -> PersonChoice {
        guard let suggestion = group.suggestion else { return VoicePersonPicker.newPersonChoice }
        return registryChoices.first { $0.personKey == suggestion.personKey } ?? suggestion
    }

    /// The not-yet-registered attendee suggestion (when there is one) first,
    /// then the whole registry — a Train group isn't scoped to one meeting's
    /// invite list the way a queue card is.
    private var candidates: [PersonChoice] {
        guard let suggestion = group.suggestion, !suggestion.inRegistry,
              !registryChoices.contains(where: { $0.personKey == suggestion.personKey })
        else { return registryChoices }
        return [suggestion] + registryChoices
    }

    /// Audio-less members, tallied by distinct meeting — spec §4.2: "no card
    /// without audio", so these never get their own clip row, only this line.
    private var audiolessMeetingCount: Int {
        Set(group.members.filter { !$0.hasAudio }.map(\.transcriptID)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(group.audioMembers, id: \.key) { member in
                if let clip = clips[member.key] {
                    ForEach(Array(clip.clips.enumerated()), id: \.offset) { index, span in
                        VoiceClipRow(
                            clip: span, text: clip.clipTexts.indices.contains(index) ? clip.clipTexts[index] : "",
                            isFirst: isActive && index == 0 && member.key == group.audioMembers.first?.key,
                            isPlaying: isPlaying(span, clip.audioPath)) {
                            onPlay(span, clip.audioPath)
                        }
                    }
                }
            }
            if audiolessMeetingCount > 0 {
                Text("+\(audiolessMeetingCount) meeting\(audiolessMeetingCount == 1 ? "" : "s") without audio — will be labeled from this")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !group.hint.isEmpty {
                Text(group.hint).font(.caption).foregroundStyle(.secondary)
            }
            VoicePersonPicker(groups: [CandidateGroup(title: "", choices: candidates)], selection: $selectedCandidate,
                              newName: $newName, newEmail: $newEmail)
            actions
        }
        .padding(12)
        .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(group.members.count) meeting\(group.members.count == 1 ? "" : "s")").fontWeight(.semibold)
            Text("·").foregroundStyle(.secondary)
            Text("\(Int(group.speechMin)) min speech").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
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
            Button("Several people") { onDismiss(true) }
            Button("Don't know") { onDismiss(false) }
            Spacer()
        }
        .controlSize(.small)
    }

    private func confirm() {
        guard let resolved = VoicePersonPicker.resolve(selection: selectedCandidate, newName: newName, newEmail: newEmail) else { return }
        onConfirm(resolved)
    }
}
