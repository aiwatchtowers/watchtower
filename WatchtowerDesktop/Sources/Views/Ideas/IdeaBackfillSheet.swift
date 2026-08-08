import SwiftUI

// MARK: - IdeaBackfillSheet
//
// "Find ideas" backfill: runs `watchtower ideas mine --from --to` over a
// historical window (Settings-driven default; this sheet is the on-demand
// entry point). Run state (`isBackfilling`/`backfillSummary`/`backfillError`)
// lives on `IdeasViewModel`, not here — so dismissing the sheet and reopening
// it (or switching tabs and back) still shows an in-flight or just-finished
// run instead of losing it.
struct IdeaBackfillSheet: View {
    let vm: IdeasViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var fromDate: Date
    @State private var toDate = Date()
    @State private var startedAt: Date?

    private enum Preset {
        case twoWeeks, month, quarter
    }

    init(vm: IdeasViewModel) {
        self.vm = vm
        _fromDate = State(initialValue: Self.date(monthsAgo: 0, weeksAgo: 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            formContent
            Divider()
            sheetFooter
        }
        .frame(width: 440, height: 340)
        // Starting a run does not dismiss the sheet — the owner watches
        // progress inline and closes explicitly once done.
        .onChange(of: vm.isBackfilling) { _, isBackfilling in
            if isBackfilling { startedAt = Date() }
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text("Find Ideas")
                .font(.headline)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mine ideas, notes, and decisions from a past date range — the daemon's regular pass only looks at recent activity.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("2 weeks") { apply(.twoWeeks) }
                Button("Month") { apply(.month) }
                Button("Quarter") { apply(.quarter) }
            }
            .buttonStyle(.bordered)
            .disabled(vm.isBackfilling)

            DatePicker("From", selection: $fromDate, in: ...toDate, displayedComponents: .date)
                .disabled(vm.isBackfilling)
            DatePicker("To", selection: $toDate, in: ...Date(), displayedComponents: .date)
                .disabled(vm.isBackfilling)

            runningIndicator
            resultText
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if vm.isBackfilling {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Mining ideas…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.elapsedString(from: startedAt, to: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Errors take priority over a stale summary from a previous run — the
    /// VM only clears fields on success (clear-only-on-success), so both can
    /// be non-nil at once after success-then-failure.
    @ViewBuilder
    private var resultText: some View {
        if vm.isBackfilling {
            EmptyView()
        } else if let error = vm.backfillError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else if let summary = vm.backfillSummary {
            Label(summary, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("Start", action: start)
                .buttonStyle(.borderedProminent)
                .disabled(vm.isBackfilling)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// Fires an unstructured `Task`, not a view-scoped `.task` — the run must
    /// keep going even if this sheet is dismissed (state lives on the VM).
    private func start() {
        let from = fromDate
        let to = toDate
        Task { await vm.startBackfill(from: from, to: to) }
    }

    private func apply(_ preset: Preset) {
        let now = Date()
        switch preset {
        case .twoWeeks:
            fromDate = Self.date(monthsAgo: 0, weeksAgo: 2)
        case .month:
            fromDate = Self.date(monthsAgo: 1, weeksAgo: 0)
        case .quarter:
            fromDate = Self.date(monthsAgo: 3, weeksAgo: 0)
        }
        toDate = now
    }

    private static func date(monthsAgo: Int, weeksAgo: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let afterMonths = calendar.date(byAdding: .month, value: -monthsAgo, to: now) ?? now
        return calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: afterMonths) ?? afterMonths
    }

    private static func elapsedString(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
