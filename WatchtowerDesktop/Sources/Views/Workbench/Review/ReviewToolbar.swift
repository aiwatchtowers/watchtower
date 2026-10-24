import AppKit
import SwiftUI
import WatchtowerCore

/// The Branch review toolbar (board #712, spec §4.3): All changes / Since
/// round N−1 from round 2, Quick / Deep, Deep's phase strip; then Inline,
/// Refresh, Agent chat (#962), ⋯ and the one prominent action — Send review
/// (N), or Start next round once the round was sent.
struct ReviewToolbar: View {
    let model: ReviewChangesModel
    @Binding var inline: Bool
    /// Re-reads the tree of an open round, or opens the next round once
    /// this one was sent (Start next round).
    let refresh: () -> Void
    /// Find Repeats…: nil = no lessons model (no CLI), the item is off.
    var findRepeats: (() -> Void)?
    /// Open in Terminal: the session's terminal beside the pane; nil = the item is off.
    var openTerminal: (() -> Void)?
    /// The session agent's chat panel is open; nil = no panel, no button.
    var chatPanel: Binding<Bool>?

    private var roundOpen: Bool { model.round?.status == "open" }
    /// Quick and Deep's Chapters show a diff, so Inline applies.
    private var showsDiff: Bool { model.mode == .quick || model.phase == .chapters }

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            if let round = model.round, round.prevRoundId > 0 {
                KitSegmentedPicker(
                    title: "View",
                    selection: Binding(get: { model.view }, set: { view in Task { await model.setView(view) } }),
                    segments: [
                        KitSegment(value: ReviewChangesModel.View.all, title: "All changes"),
                        KitSegment(value: .sinceLastRound, title: "Since round \(round.prevRoundId)")
                    ]
                )
            }
            KitSegmentedPicker(
                title: "Mode",
                // A failure lands in lastError.
                selection: Binding(get: { model.mode }, set: { mode in Task { try? await model.setMode(mode) } }),
                segments: [
                    KitSegment(value: ReviewChangesModel.Mode.quick, title: "Quick"),
                    KitSegment(value: .deep, title: "Deep")
                ]
            )
            .disabled(!roundOpen)
            .help("Quick: files and a diff. Deep: meaning, chapters with checklists, wrap-up")
            if model.mode == .deep { ReviewPhaseStrip(model: model) }
            Spacer(minLength: Spacing.small)
            if showsDiff {
                Button { inline.toggle() } label: { Image(systemName: "rectangle.split.1x2") }
                    .buttonStyle(.kitIcon(isOn: inline))
                    .help("Inline: one column instead of side by side")
                    .accessibilityLabel("Inline")
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.kitIcon(isOn: false))
                .disabled(!roundOpen || model.load != .ready || model.sending || model.refreshing)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            if let chatPanel {
                Button { chatPanel.wrappedValue.toggle() } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .buttonStyle(.kitIcon(isOn: chatPanel.wrappedValue))
                    .keyboardShortcut("c", modifiers: [.option, .command])
                    .help("Agent chat: the session's Workchat beside the review (⌥⌘C)")
                    .accessibilityLabel("Agent chat")
            }
            moreMenu
            if roundOpen {
                Button("Send review (\(model.draftCount))") { Task { await model.send() } }
                    .buttonStyle(.kitPrimary)
                    .disabled(!Self.canSend(model))
                    .help("Send the drafts (and the comments carried from the last round) to the agent")
            } else {
                Button("Start next round", action: refresh)
                    .buttonStyle(.kitPrimary)
                    .disabled(model.load != .ready || model.sending || model.refreshing)
                    .help("Open a new round on the folder as it is now")
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.compact)
    }

    private var moreMenu: some View {
        Menu {
            Button("Find Repeats…") { findRepeats?() }
                .disabled(findRepeats == nil)
                .help("Propose house rules from comments you keep repeating")
            Button("Show in Finder", action: showInFinder)
                .disabled(model.round?.folderRoot.isEmpty ?? true)
            Button("Open in Terminal") { openTerminal?() }
                .disabled(openTerminal == nil)
                .help("Show the session's terminal beside the review")
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    /// The selected file in Finder, else the folder the round reviews.
    private func showInFinder() {
        guard let root = model.round?.folderRoot, !root.isEmpty else { return }
        let folder = URL(fileURLWithPath: root)
        let target = model.selectedPath.map { folder.appendingPathComponent($0) } ?? folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    static func canSend(_ model: ReviewChangesModel) -> Bool {
        let carried = model.comments.contains { $0.status == .carried }
        return model.load == .ready && !model.sending && !model.refreshing && (model.draftCount > 0 || carried)
    }

    /// `<viewed>/<total> lines · <done>/<count> chapters · <h:mm> active`.
    static func progressLine(_ model: ReviewChangesModel) -> String {
        let p = model.progress
        let seconds = model.pace.activeSeconds
        let time = String(format: "%d:%02d", seconds / 3600, seconds % 3600 / 60)
        return "\(p.viewedLines)/\(p.totalLines) lines · \(p.chaptersDone)/\(p.chapterCount) chapters · \(time) active"
    }

    static func deliveryText(_ delivery: SessionLineDelivery.Delivery?) -> String? {
        switch delivery {
        case .typed: "Line pasted — press Return in the terminal"
        case .copied: "Copied — paste it into the terminal"
        case .held: "Will be sent when the agent's turn ends"
        default: nil
        }
    }
}

/// The round's notices under the toolbar: the break hint, a lost snapshot,
/// a truncated diff, how Send delivered, the last error. They show in the
/// empty state too, so a failed refresh is never hidden.
struct ReviewBanners: View {
    let model: ReviewChangesModel

    var body: some View {
        if model.mode == .deep, model.pace.breakHintDue, !model.breakHintDismissed {
            ReviewBanner(text: "You have reviewed for an hour — a short break helps you catch more.") {
                model.breakHintDismissed = true
            }
        }
        if model.previousTreeLost, let round = model.round {
            ReviewBanner(text: "Round \(round.prevRoundId)'s snapshot is gone — showing all changes")
        }
        if model.truncated {
            ReviewBanner(text: "The diff is too large; later files show without hunks")
        }
        if let text = ReviewToolbar.deliveryText(model.lastSend) {
            ReviewBanner(text: text)
        }
        if let error = model.lastError {
            ReviewBanner(text: error, isError: true) { model.clearError() }
        }
    }
}

/// One line under the header; an error one can be dismissed.
struct ReviewBanner: View {
    let text: String
    var isError = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.compact) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Tone.warning : Color.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.small)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .font(.caption)
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.small)
        // The same values as before the move, from the kit's scale.
        .background(isError ? Tone.warning.opacity(Fill.selectedOpacity) : Fill.rest)
    }
}
