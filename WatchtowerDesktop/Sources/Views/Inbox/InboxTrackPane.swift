import SwiftUI
import WatchtowerCore

/// The Inbox's track card (C1 §6.2, R4): `TrackDetailView` over the
/// AppState-owned `TracksViewModel`. Opening it writes nothing; **Done**
/// marks the track and its events read, **Stop watching** (⋯) dismisses it
/// (a custom track's collection also stops, through `controls`). A custom
/// track's Collecting toggle, instruction and scans go only through
/// `controls`, the seam C3 swaps for the track's watch recipe. A stopped
/// track's card (the Tracks filter's Stopped fold) offers **Restore**.
struct InboxTrackPane: View {
    let card: InboxTrackCard
    let tracks: TracksViewModel
    let controls: any CustomTrackControlling
    /// The card's Done or Stop watching is under way.
    let isWriting: Bool
    let onDone: () -> Void
    let onStopWatching: () -> Void
    let onRestore: () -> Void
    let onCommand: (InboxCardCommand) -> Void
    let workbenches: [Workbench]

    init(
        card: InboxTrackCard,
        tracks: TracksViewModel,
        controls: any CustomTrackControlling,
        isWriting: Bool = false,
        onDone: @escaping () -> Void,
        onStopWatching: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onCommand: @escaping (InboxCardCommand) -> Void,
        workbenches: [Workbench]
    ) {
        self.card = card
        self.tracks = tracks
        self.controls = controls
        self.isWriting = isWriting
        self.onDone = onDone
        self.onStopWatching = onStopWatching
        self.onRestore = onRestore
        self.onCommand = onCommand
        self.workbenches = workbenches
    }

    var body: some View {
        TrackDetailView(
            card: card, viewModel: tracks, controls: controls, isWriting: isWriting,
            onDone: onDone, onStopWatching: onStopWatching, onRestore: onRestore, onCommand: onCommand,
            workbenches: workbenches
        )
        // Another track starts with its own edits, folds and inline rows.
        .id(card.track.id)
    }
}

/// What the track card shows of its own: a custom track's reflected
/// Collecting and instruction (they change before the next read), its
/// instruction editor, and which inline row or fold is open.
struct TrackCardState: Equatable {
    var collecting: Bool
    var instruction: String
    var editingInstruction = false
    var draftInstruction = ""
    /// A failed toggle or instruction save — e.g. the watch was deleted
    /// elsewhere. Cleared by the next successful edit.
    var watchEditError: String?
    var scanRowOpen = false
    var showsEarlier = false
    var confirmingDelete = false

    init(track: Track) {
        collecting = track.enabled
        instruction = track.instruction
    }
}

/// The track card's buttons: the Inbox's common row with **Done** and a ⋯
/// menu — **Stop watching**, **Make a Task** for an extracted track (R9),
/// and for a custom track **Go to Target** (when linked) and **Delete…**,
/// which asks inline, never in a dialog. A stopped track shows **Restore**
/// in Done's place, and its menu has no Stop watching.
struct TrackCardActions: View {
    let subject: InboxCardSubject
    let link: URL?
    let isCustom: Bool
    let isStopped: Bool
    let linkedTargetID: Int?
    let navScreens: Set<String>
    let workbenches: [Workbench]
    let isWriting: Bool
    let isMakingTask: Bool
    @Binding var confirmingDelete: Bool
    let onCommand: (InboxCardCommand) -> Void
    let onDone: () -> Void
    let onStopWatching: () -> Void
    let onRestore: () -> Void
    let onMakeTask: () -> Void
    let onGoToTarget: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            InboxCommonRow(
                subject: subject,
                link: link,
                openLabel: "Open in Slack",
                navScreens: navScreens,
                workbenches: workbenches,
                isWriting: isWriting,
                onCommand: onCommand
            ) {
                if isStopped {
                    Button("Restore", action: onRestore)
                } else {
                    Button("Done", action: onDone)
                }
                more
            }
            if confirmingDelete {
                deleteRow
            }
        }
    }

    private var more: some View {
        Menu {
            if !isStopped {
                Button("Stop watching", action: onStopWatching)
            }
            if !isCustom {
                Button("Make a Task", action: onMakeTask)
                    .disabled(isMakingTask)
            }
            if isCustom, let linkedTargetID {
                Button("Go to Target") { onGoToTarget(linkedTargetID) }
            }
            if isCustom {
                Button("Delete…") { confirmingDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    private var deleteRow: some View {
        HStack(spacing: Spacing.regular) {
            Text("Delete — this can't be undone")
                .font(.callout)
            Spacer()
            Button("Delete") {
                confirmingDelete = false
                onDelete()
            }
            .buttonStyle(.kitDestructive)
            Button("Cancel") { confirmingDelete = false }
                .buttonStyle(.kitQuiet)
        }
        .controlSize(.small)
        .padding(Spacing.medium)
        .card()
    }
}

/// A custom track's Collecting / Paused toggle and its watch instruction
/// with an inline editor. Both write only through `controls`; a failure
/// keeps what was shown (the editor stays open with the draft) and says why.
struct CustomTrackControlsSection: View {
    let track: Track
    let controls: any CustomTrackControlling
    @Binding var state: TrackCardState
    /// The watch is gone (deleted elsewhere): the tracks list reloads.
    let onWatchGone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.regular) {
                Toggle(isOn: Binding(get: { state.collecting }, set: { on in Task { await setCollecting(on) } })) {
                    Text(state.collecting ? "Collecting" : "Paused")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(state.collecting
                      ? "The daemon scans this watch each cycle. Turn off to pause."
                      : "Paused — the daemon skips this watch until re-enabled.")
                Spacer()
                if !state.editingInstruction {
                    Button {
                        state.draftInstruction = state.instruction
                        state.editingInstruction = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Watch instruction").font(.headline)
                if state.editingInstruction {
                    editor
                } else if !state.instruction.isEmpty {
                    Text(verbatim: state.instruction)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = state.watchEditError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Tone.status("red"))
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            TextField("What to watch for…", text: $state.draftInstruction, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.kit)
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") { state.editingInstruction = false }
                    .buttonStyle(.kitQuiet)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private var draft: String { state.draftInstruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Saves the draft and shows it once the write lands.
    func save() async {
        let text = draft
        guard !text.isEmpty else { return }
        do {
            try await controls.saveInstruction(track, text: text)
            state.watchEditError = nil
            state.instruction = text
            state.editingInstruction = false
        } catch {
            failed("save the instruction", error)
        }
    }

    /// Turns collecting on or off once the write lands; a failure leaves the toggle.
    func setCollecting(_ on: Bool) async {
        do {
            try await controls.setCollecting(track, on: on)
            state.watchEditError = nil
            state.collecting = on
        } catch {
            failed("update collecting", error)
        }
    }

    private func failed(_ what: String, _ error: Error) {
        if error is RowNotFoundError { onWatchGone() }
        state.watchEditError = "Failed to \(what): \(error.localizedDescription)"
    }
}
