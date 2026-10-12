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
                    WorkbenchView(replica: replica, writer: env.boardWriter, workbenchID: route.id)
                }
                .navigationDestination(for: BoardTargetRoute.self) { route in
                    BoardTargetDetailView(replica: replica, writer: env.boardWriter, targetID: route.id)
                }
                .navigationDestination(for: SessionRoute.self) { route in
                    SessionDetailView(replica: replica, sessionID: route.id, store: env.store, requester: env.reportRequests)
                }
                .navigationDestination(for: AskRoute.self) { route in
                    AskView(replica: replica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: route.id)
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
                        .listRowInsets(RowInsets.flat)
                    }
                } header: {
                    Text(workbenches.count == 1 ? "1 folder on your Mac" : "\(workbenches.count) folders on your Mac")
                        .font(TypeScale.sectionHeader)
                        .textCase(nil)
                } footer: {
                    Text("Workbenches are folders bound on the Mac. New ones are added there.")
                        .font(TypeScale.meta)
                }
            }
            .listStyle(.plain)
            .refreshable { await env.refresh() }
        }
    }
}

/// One Workbench list row (design pass spec W1–W3): the name and its pills,
/// the folder and the branch, then compact session counts with the board's
/// progress.
struct WorkbenchCardView: View {
    let card: WorkbenchCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text(card.name).font(TypeScale.rowEmphasis).lineLimit(1)
                Spacer(minLength: Spacing.regular)
                ForEach(card.pills) { pill in
                    Pill(text: pill.text, tone: pill.tone, style: pill.tone == .secondary ? .neutral : .tinted)
                }
            }
            HStack(spacing: Spacing.compact) {
                Text(card.folder)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = card.branch {
                    Pill(text: branch, style: .neutral, monospaced: true)
                }
            }
            // Wraps at large Dynamic Type instead of squeezing (Phases 1–2
            // review). The bar and its text are one item, so the bar stays
            // centred on the text.
            FlowRow(spacing: Spacing.regular) {
                ForEach(card.stateCounts) { count in
                    HStack(spacing: 3) {
                        SessionDot(tone: count.tone, isRing: count.isRing, size: 7)
                        Text("\(count.amount)").font(TypeScale.time).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(count.text)
                }
                HStack(spacing: Spacing.compact) {
                    if let progress = card.progress {
                        ThinProgressBar(value: progress, tone: card.progressTone).frame(width: 64)
                    }
                    Text(card.doneLine).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
        }
    }
}
