import SwiftUI

/// The Now tab: the date, the Mac chip, the next meeting with Record,
/// Waiting for you across every workbench and the session summary.
struct NowView: View {
    @Environment(AppEnvironment.self) private var env

    private var replica: WorkbenchReplicaModel { env.workbenchReplica }

    var body: some View {
        NavigationStack {
            // The Mac chip turns offline by the clock alone, and ages tick.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(NowModel(snapshot: replica.snapshot, now: context.date), date: context.date)
            }
            .navigationTitle("Now")
            .navigationDestination(for: String.self) { EventDetailView(eventID: $0) }
            .navigationDestination(for: AskRoute.self) { route in
                AskView(replica: replica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: route.id)
            }
            .refreshable { await env.refresh() }
        }
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
            if let next = NextMeetingCardModel(events: env.calendarReplica.snapshot.events, now: date, calendar: .current) {
                Section {
                    NextMeetingCardView(card: next)
                }
            }
            Section {
                if let empty = model.emptyText {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    ForEach(model.waiting) { card in
                        NavigationLink(value: AskRoute(id: card.id)) { WaitingCardView(card: card) }
                            .listRowSeparator(.hidden)
                    }
                    if model.waitingMore > 0 {
                        Text("\(model.waitingMore) more on your Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Waiting for you").foregroundStyle(model.waitingHeaderTone.color)
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

/// "Next · in 25 min", the title, "14:00–14:45 · 5 people · prep ready"
/// and the red Record button; tap the card for the event.
private struct NextMeetingCardView: View {
    @Environment(AppEnvironment.self) private var env
    let card: NextMeetingCardModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(value: card.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.header).font(.caption.weight(.semibold)).foregroundStyle(PhoneTone.accent.color)
                    Text(card.title).font(.headline)
                    Text(card.line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await env.recorder.recordMeeting(card.meetingEvent) }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(PhoneTone.red.color)
            // Regular size: a hit target of at least 44 pt.
            .controlSize(.regular)
            .frame(minHeight: 44)
        }
    }
}
