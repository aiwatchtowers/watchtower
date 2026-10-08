import SwiftUI

/// The Now tab: the date, the Mac chip, Waiting for you across every
/// workbench and the session summary. Read-only; the next meeting card
/// comes with sub-project C.
struct NowView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var replica = WorkbenchReplicaModel()

    var body: some View {
        NavigationStack {
            // The Mac chip turns offline by the clock alone, and ages tick.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(NowModel(snapshot: replica.snapshot, now: context.date), date: context.date)
            }
            .navigationTitle("Now")
            .refreshable { await env.refresh() }
        }
        .task { replica.start(store: env.store) }
    }

    private func content(_ model: NowModel, date: Date) -> some View {
        List {
            Section {
                HStack {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(model.macChipTone.color).frame(width: 7, height: 7)
                        Text(model.macChip)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            Section("Waiting for you") {
                if let empty = model.emptyText {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    ForEach(model.waiting) { WaitingCardView(card: $0).listRowSeparator(.hidden) }
                    if model.waitingMore > 0 {
                        Text("\(model.waitingMore) more on your Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Sessions") {
                if model.sessionChips.isEmpty {
                    Text("No sessions running").foregroundStyle(.secondary)
                } else {
                    FlowCounts(counts: model.sessionChips)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
