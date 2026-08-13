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
        switch mode {
        case .note:
            return existing + "\n\n"
        case .idea, .chat:
            return existing + " "
        }
    }

    /// `base` plus the dictated chunk verbatim (no trimming — whitespace the
    /// engine produced is kept as-is). An empty chunk collapses back to the
    /// original existing text by trimming `base`'s trailing separator.
    static func compose(base: String, dictated: String) -> String {
        guard !dictated.isEmpty else {
            return base.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // center.stop() is global — a button for a target that isn't the
            // one actually recording must not stop someone else's dictation.
            if center.activeTargetID == targetID { center.stop() }
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
        if center.activeTargetID == targetID, case .recording = center.phase {
            stopButton(center)
        } else if center.activeTargetID == targetID, center.phase == .loadingEngine {
            // The spinner doubles as a cancel affordance: before the engine
            // has loaded there is nothing worth keeping, and center.stop()
            // during the load cancels the dictation outright.
            Button {
                center.stop()
            } label: {
                ProgressView()
                    .controlSize(.small)
            }
            .buttonStyle(.plain)
            .help("Cancel dictation")
        } else if center.activeTargetID == targetID, center.phase == .cleaning {
            ProgressView()
                .controlSize(.small)
        } else if center.activeTargetID == targetID, case .failed(let message) = center.phase {
            retryButton(center, message: message)
        } else {
            idleButton(center)
        }
    }

    private func idleButton(_ center: DictationCenter) -> some View {
        let anotherActive = center.activeTargetID != nil && center.activeTargetID != targetID
        let disabled = center.meetingBusy() || isDisabled || anotherActive
        return Button {
            startDictation(center)
        } label: {
            Image(systemName: "mic.fill")
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? disabledReason(center: center, anotherActive: anotherActive) : "Dictate")
    }

    private func stopButton(_ center: DictationCenter) -> some View {
        Button {
            center.stop()
        } label: {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        }
        .buttonStyle(.plain)
        .help("Stop dictating (Esc)")
    }

    private func retryButton(_ center: DictationCenter, message: String) -> some View {
        Button {
            center.retry()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
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
                text = DictationSpan.compose(base: base, dictated: raw)
            },
            onResult: { result in
                guard !(result.text.isEmpty && result.title == nil) else {
                    text = base.trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                text = DictationSpan.compose(base: base, dictated: result.text)
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
                text = DictationSpan.compose(base: base, dictated: raw)
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
        text = DictationSpan.compose(base: revert.base, dictated: revert.raw)
        clearRevert()
    }

    private func clearRevert() {
        revertDismissTask?.cancel()
        revertDismissTask = nil
        revert = nil
    }
}
