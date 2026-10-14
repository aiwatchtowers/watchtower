import SwiftUI
import WatchtowerCore

/// A session row's **Clean Up…** (board #535, spec
/// 2026-10-12-session-cleanup §12): the plan with the `remove` items ticked
/// and the kept ones greyed with their reason in words, the total of what
/// is ticked; **Clean Up** applies exactly the ticked keys and shows the
/// result. The plan and the result live in `SessionCleanupCenter` and the
/// apply runs on the view model, so an apply goes on when the sheet closes
/// (its failure then shows on the page); the ticks are this sheet's.
struct SessionCleanupSheet: View {
    let vm: WorkbenchesViewModel
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var ticked: Set<String> = []

    var body: some View {
        let phase = vm.sessionCleanup?.cleanupPhase(for: .session(session.id)) ?? .idle
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean up “\(session.title)”").font(.headline)
            SessionCleanupPhaseView(phase: phase, ticked: $ticked) {
                Task { await vm.planCleanupForSheet(session) }
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            footer(phase)
        }
        .padding(20)
        .frame(width: 540)
        .task(id: session.id) { await vm.planCleanupForSheet(session) }
        .onAppear { vm.cleanupSheetAppeared(session) }
        .onDisappear { vm.cleanupSheetDisappeared(session) }
        .onChange(of: phase, initial: true) { _, now in
            if case let .ready(plan) = now { ticked = Set(plan.removableKeys) }
        }
    }

    @ViewBuilder
    private func footer(_ phase: SessionCleanupPhase) -> some View {
        HStack {
            if case .ready = phase {
                let chosen = vm.sheetCleanupChoice(session, ticked: ticked)
                Text(SessionCleanupPresentation.totalText(chosen) ?? "Nothing selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean Up", role: .destructive) {
                    let (vm, session, ticked) = (vm, session, ticked)
                    Task { await vm.applySheetCleanup(session, ticked: ticked) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            } else {
                Spacer()
                Button(phase == .applying ? "Close" : "Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func close() {
        vm.closeCleanupSheet(session)
        dismiss()
    }
}

/// The sheet's body for one phase.
private struct SessionCleanupPhaseView: View {
    let phase: SessionCleanupPhase
    @Binding var ticked: Set<String>
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .idle, .planning:
            ProgressView(SessionDeleteCleanupOffer.checkingText).controlSize(.small)
        case .applying:
            ProgressView("Cleaning up…").controlSize(.small)
        case let .ready(plan):
            itemList(plan.items, emptyText: "Nothing to clean up: this session left no worktree or branch to remove.")
        case let .done(result):
            VStack(alignment: .leading, spacing: 8) {
                if !result.summary.isEmpty { Text(result.summary) }
                itemList(result.items, emptyText: "Nothing was removed.")
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
            }
        }
    }

    @ViewBuilder
    private func itemList(_ items: [SessionCleanupItem], emptyText: String) -> some View {
        if items.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        SessionCleanupItemRow(item: item, ticked: tickBinding(item))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
    }

    /// A pending removal's tick; nil for an item that cannot be ticked.
    private func tickBinding(_ item: SessionCleanupItem) -> Binding<Bool>? {
        guard item.isPendingRemoval, case .ready = phase else { return nil }
        return Binding(
            get: { ticked.contains(item.key) },
            set: { on in
                if on { ticked.insert(item.key) } else { ticked.remove(item.key) }
            }
        )
    }
}

/// One plan or result item: a tick for a pending removal, else its outcome
/// — removed, kept with the reason in words, or the error.
private struct SessionCleanupItemRow: View {
    let item: SessionCleanupItem
    let ticked: Binding<Bool>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let ticked {
                Toggle(isOn: ticked) { label }
                    .toggleStyle(.checkbox)
            } else {
                label.foregroundStyle(item.action == .keep ? .secondary : .primary)
            }
        }
        .help(item.detail)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).lineLimit(1).truncationMode(.middle)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(item.error.isEmpty ? Color.secondary : Color.red)
            }
        }
    }

    private var title: String {
        let name = item.name.isEmpty ? item.key : item.name
        let branch = item.kind == .worktree && !item.branch.isEmpty ? " (\(item.branch))" : ""
        return "\(Self.kindWord(item.kind)) \(name)\(branch)"
    }

    /// The size of a worktree, the reason of a kept item, the error of a
    /// failed one, "Removed" for a done one.
    private var note: String? {
        if !item.error.isEmpty { return "Failed: \(item.error)" }
        if item.done { return "Removed" }
        if item.action == .keep { return "Kept — " + SessionCleanupPresentation.reasonText(item.reason ?? .unknown("")) }
        guard item.kind == .worktree else { return nil }
        return SessionCleanupPresentation.sizeText(bytes: item.bytes, known: item.bytesKnown)
    }

    private static func kindWord(_ kind: SessionCleanupItem.Kind) -> String {
        switch kind {
        case .worktree: "Worktree"
        case .branch: "Branch"
        case .process: "Process"
        case .lsreg: "LaunchServices entry"
        case let .unknown(raw): raw
        }
    }
}
