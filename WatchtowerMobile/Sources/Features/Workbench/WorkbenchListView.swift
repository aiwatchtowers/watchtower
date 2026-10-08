import SwiftUI

struct WorkbenchRoute: Hashable {
    let id: Int64
}

struct BoardTargetRoute: Hashable {
    let id: Int64
}

/// The Workbench tab, level 1 (spec §4.2): one card per workbench with its
/// folder, branch, waiting count, session-state counts and board progress.
/// Read-only. Owns the tab's replica observation; every level below reads
/// the same model, so it survives navigation.
struct WorkbenchListView: View {
    @Environment(AppEnvironment.self) private var env

    private var replica: WorkbenchReplicaModel { env.workbenchReplica }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Workbenches")
                .navigationDestination(for: WorkbenchRoute.self) { route in
                    WorkbenchView(replica: replica, workbenchID: route.id)
                }
                .navigationDestination(for: BoardTargetRoute.self) { route in
                    BoardTargetDetailView(replica: replica, targetID: route.id)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let workbenches = replica.snapshot.orderedWorkbenches
        if workbenches.isEmpty {
            ContentUnavailableView(
                "No workbenches yet",
                systemImage: "hammer",
                description: Text("Your Mac's workbenches show up here.")
            )
        } else {
            List {
                Section {
                    ForEach(workbenches) { workbench in
                        NavigationLink(value: WorkbenchRoute(id: workbench.id)) {
                            WorkbenchCardView(card: WorkbenchCardModel(workbench))
                        }
                    }
                } header: {
                    Text(workbenches.count == 1 ? "1 folder on your Mac" : "\(workbenches.count) folders on your Mac")
                } footer: {
                    Text("Workbenches are folders bound on the Mac. New ones are added there.")
                }
            }
            .refreshable { await env.refresh() }
        }
    }
}

/// One Workbench list card.
struct WorkbenchCardView: View {
    let card: WorkbenchCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ForEach(card.pills) { CountPill(text: $0.text, tone: $0.tone) }
            }
            Text([card.folder, card.branch].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !card.stateCounts.isEmpty {
                FlowCounts(counts: card.stateCounts)
            }
            if let progress = card.progress {
                ThinProgressBar(value: progress, tone: card.progressTone)
            }
            Text(card.countsLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Session-state counts on one wrapping line.
struct FlowCounts: View {
    let counts: [SessionStateCount]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(counts) { SessionCountLabel(count: $0) }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(counts) { SessionCountLabel(count: $0) }
            }
        }
    }
}
