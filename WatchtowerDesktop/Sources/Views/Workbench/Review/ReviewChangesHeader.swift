import SwiftUI
import WatchtowerCore

/// The Changes pane's header (board #328): the round's base and number, the
/// All / Since round view, Refresh and Send review; then its banners.
struct ReviewChangesHeader: View {
    let model: ReviewChangesModel
    @Binding var inline: Bool
    /// Refresh: re-reads the tree of an open round, or opens the next round
    /// once this one was sent.
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let round = model.round {
                    Text("Base: \(round.baseLabel.isEmpty ? "empty tree" : round.baseLabel)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(round.baseSha.isEmpty ? "empty tree" : round.baseSha)
                    Text("Round #\(round.id)").foregroundStyle(.secondary)
                    if round.prevRoundId > 0 {
                        Picker("View", selection: Binding(
                            get: { model.view },
                            set: { view in Task { await model.setView(view) } }
                        )) {
                            Text("All").tag(ReviewChangesModel.View.all)
                            Text("Since round \(round.prevRoundId)").tag(ReviewChangesModel.View.sinceLastRound)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Picker("Mode", selection: Binding(
                    get: { model.mode },
                    set: { try? model.setMode($0) } // a failure lands in lastError
                )) {
                    Text("Quick").tag(ReviewChangesModel.Mode.quick)
                    Text("Deep").tag(ReviewChangesModel.Mode.deep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.round?.status != "open")
                .help("Quick: files and a diff. Deep: meaning, chapters with checklists, wrap-up")
                if model.mode == .deep { Text(Self.progressLine(model)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Toggle("Inline", isOn: $inline)
                    .toggleStyle(.checkbox)
                    .help("One column instead of side by side")
                Button("Refresh", action: refresh)
                    .disabled(model.load != .ready || model.sending || model.refreshing)
                Button("Send review (\(model.draftCount))") { Task { await model.send() } }
                    .disabled(!Self.canSend(model))
                    .help("Send the drafts (and the comments carried from the last round) to the agent")
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            banners
        }
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

    @ViewBuilder private var banners: some View {
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
        if let text = Self.deliveryText(model.lastSend) {
            ReviewBanner(text: text)
        }
        if let error = model.lastError {
            ReviewBanner(text: error, isError: true) { model.clearError() }
        }
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

/// One line under the header; an error one can be dismissed.
struct ReviewBanner: View {
    let text: String
    var isError = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : Color.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isError ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04))
    }
}
