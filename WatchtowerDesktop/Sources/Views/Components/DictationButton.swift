import SwiftUI

/// Pure span-management math for dictation, extracted out of `DictationButton`
/// so it's testable without ViewInspector. The button captures `base` once
/// when a dictation starts, then re-derives the bound text from `base` plus
/// whatever the engine has produced so far (live chunks, then the cleaned
/// result) — never by mutating the field incrementally.
enum DictationSpan {
    /// The text a dictation starts appending after: the existing field
    /// content, with a mode-appropriate separator when it's non-empty. An
    /// empty field needs no separator — the dictation IS the whole field.
    static func base(existing: String, mode: DictationMode) -> String {
        guard !existing.isEmpty else { return existing }
        return existing + separator(for: mode)
    }

    /// The mode-appropriate separator `base` appends after non-empty existing
    /// text — the exact suffix `compose` strips back off when a dictation
    /// comes back empty.
    private static func separator(for mode: DictationMode) -> String {
        switch mode {
        case .note:
            return "\n\n"
        case .idea, .chat:
            return " "
        }
    }

    /// `base` plus the dictated chunk verbatim (no trimming — whitespace the
    /// engine produced is kept as-is). An empty chunk collapses back to the
    /// original existing text by dropping only `base`'s trailing separator —
    /// never a blanket trim, which would also eat whitespace the existing
    /// text started with (a Notes field holding "\n  draft" must stay exactly
    /// that after an empty dictation).
    static func compose(base: String, dictated: String, mode: DictationMode) -> String {
        guard !dictated.isEmpty else {
            let sep = separator(for: mode)
            return base.hasSuffix(sep) ? String(base.dropLast(sep.count)) : base
        }
        return base + dictated
    }
}

/// Mic button + span management for one text binding. Renders nothing when
/// no DictationCenter is in the environment (tests, previews).
struct DictationButton: View {
    @Binding var text: String
    let mode: DictationMode
    let targetID: String                 // unique per field, e.g. "idea-create.essence"
    var onTitle: ((String) -> Void)?     // idea mode: cleaned title, fired only when non-nil
    var isDisabled: Bool = false         // parent-supplied extra gate (e.g. notes isGenerating)
    /// Explicit center for hosts that already resolved the environment value
    /// themselves (`ChatInputContent`, tests) — ViewInspector cannot inject
    /// custom `@Environment` values, hence the parameter. nil → the
    /// environment center, as before.
    var center: DictationCenter?

    @Environment(\.dictationCenter) private var environmentCenter

    /// Armed only after a successful cleanup — mirrors the utterance-delete
    /// undo toast (`RecordingDetailTabs.swift`): a transient "Raw" affordance
    /// that reverts to the uncleaned transcript, auto-dismissing after 5 s.
    @State private var revert: (base: String, raw: String)?
    @State private var revertDismissTask: Task<Void, Never>?

    var body: some View {
        if let center = center ?? environmentCenter {
            content(center)
        }
    }

    @ViewBuilder
    private func content(_ center: DictationCenter) -> some View {
        HStack(spacing: 6) {
            button(center)
            revertToast
        }
        .onExitCommand {
            escPressed(center: center)
        }
        .onDisappear {
            // The host view is going away: nothing renders this dictation's
            // state any more and onLiveText/onResult write into a discarded
            // binding, so an owned capture is cancelled outright — mic off,
            // state reset (the QuickCaptureView onDisappear precedent).
            if center.activeTargetID == targetID { center.cancel() }
        }
    }

    @ViewBuilder
    private func button(_ center: DictationCenter) -> some View {
        if center.activeTargetID == targetID {
            switch center.phase {
            case .recording:
                recordingCapsule(center)
            case .paused:
                pausedCapsule(center)
            case .stopping:
                progressCapsule("Transcribing…")
            case .cleaning:
                progressCapsule("Cleaning…")
            case .failed(let message):
                retryButton(center, message: message)
            case .idle:
                idleButton(center)
            }
        } else {
            idleButton(center)
        }
    }

    /// Esc discards — Stop has its own always-visible button in the capsule,
    /// so finalizing on Esc would surprise anyone using it to back out.
    /// `center.cancel()` is global — a button for a target that isn't the one
    /// actually dictating must not cancel someone else's dictation, hence the
    /// ownership guard. Tests drive Esc via ViewInspector's
    /// `callOnExitCommand`, so this needs no external consumer.
    private func escPressed(center: DictationCenter) {
        guard center.activeTargetID == targetID else { return }
        center.cancel()
    }

    /// mm:ss with hours folded into minutes (3661 s → "61:01"). A negative
    /// duration (should never happen with the monotonic clock, but cheap to
    /// defend) clamps to "0:00".
    static func timerLabel(_ d: Duration) -> String {
        let totalSeconds = max(0, Int(d.components.seconds))
        return "\(totalSeconds / 60):" + String(format: "%02d", totalSeconds % 60)
    }

    private func idleButton(_ center: DictationCenter) -> some View {
        let anotherActive = center.activeTargetID != nil && center.activeTargetID != targetID
        let disabled = center.meetingBusy() || isDisabled || anotherActive
        return Button {
            startDictation(center)
        } label: {
            Image(systemName: "mic.fill")
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? disabledReason(center: center, anotherActive: anotherActive) : "Dictate")
    }

    // MARK: - Capsule states

    /// The `RecordingIndicatorView` `indicatorCapsule` look, compact.
    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
    }

    private func recordingCapsule(_ center: DictationCenter) -> some View {
        capsule {
            MicLevelBars(level: center.micLevel)
            timerText(center)
            if center.isEngineLoading {
                // The mic is already hot and buffering while the engine loads —
                // loading presents as "already listening" with this badge, and
                // Stop still finalizes (buffered speech is delivered, never
                // discarded).
                Text("Loading model…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            capsuleControl(systemName: "pause.fill", identifier: "dictation.pause",
                           help: "Pause dictation") { center.pause() }
            capsuleControl(systemName: "stop.fill", identifier: "dictation.stop",
                           help: "Stop and insert (Esc cancels)") { center.stop() }
        }
    }

    private func pausedCapsule(_ center: DictationCenter) -> some View {
        capsule {
            Text("Paused")
                .font(.caption)
                .foregroundStyle(.secondary)
            timerText(center)
            capsuleControl(systemName: "play.fill", identifier: "dictation.resume",
                           help: "Resume dictation") { center.resume() }
            capsuleControl(systemName: "stop.fill", identifier: "dictation.stop",
                           help: "Stop and insert (Esc cancels)") { center.stop() }
        }
    }

    private func progressCapsule(_ label: String) -> some View {
        capsule {
            ProgressView()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func capsuleControl(
        systemName: String,
        identifier: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .help(help)
    }

    /// The elapsed-time readout; paused time never ticks (`elapsed()` freezes
    /// while no recording span is open, so a 1 s tick cadence just re-renders
    /// the same label). The TimelineView only drives the refresh — the value
    /// itself comes from the center's monotonic clock.
    private func timerText(_ center: DictationCenter) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(Self.timerLabel(center.elapsed()))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func retryButton(_ center: DictationCenter, message: String) -> some View {
        Button {
            center.retry()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dictation.retry")
        .help(message)
    }

    @ViewBuilder
    private var revertToast: some View {
        if revert != nil {
            HStack(spacing: 6) {
                Text("Cleaned")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Raw", action: revertToRaw)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private func disabledReason(center: DictationCenter, anotherActive: Bool) -> String {
        if center.meetingBusy() { return "A meeting recording is in progress" }
        if anotherActive { return "Another field is dictating" }
        return "Dictation is unavailable"
    }

    // MARK: - Flow

    private func startDictation(_ center: DictationCenter) {
        let base = DictationSpan.base(existing: text, mode: mode)
        let onTitleCallback = onTitle
        clearRevert()
        center.start(
            targetID: targetID,
            mode: mode,
            onLiveText: { raw in
                text = DictationSpan.compose(base: base, dictated: raw, mode: mode)
            },
            onResult: { result in
                guard !(result.text.isEmpty && result.title == nil) else {
                    text = DictationSpan.compose(base: base, dictated: "", mode: mode)
                    return
                }
                text = DictationSpan.compose(base: base, dictated: result.text, mode: mode)
                if let title = result.title {
                    onTitleCallback?(title)
                }
                if let raw = center.lastRaw, !raw.isEmpty {
                    armRevert(base: base, raw: raw)
                }
            },
            onCleanupFailure: { raw in
                // Cleanup failed: the spoken words themselves must land in the
                // field. On a live provider this recomposes the same value the
                // live chunks already wrote; on a batch-only provider it is
                // the only delivery the field ever gets.
                text = DictationSpan.compose(base: base, dictated: raw, mode: mode)
            })
    }

    private func armRevert(base: String, raw: String) {
        revert = (base: base, raw: raw)
        revertDismissTask?.cancel()
        revertDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            revert = nil
        }
    }

    private func revertToRaw() {
        guard let revert else { return }
        text = DictationSpan.compose(base: revert.base, dictated: revert.raw, mode: mode)
        clearRevert()
    }

    private func clearRevert() {
        revertDismissTask?.cancel()
        revertDismissTask = nil
        revert = nil
    }
}
