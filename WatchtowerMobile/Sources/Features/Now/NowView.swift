import SwiftUI

/// A screen pushed on Now's stack: Settings, from the gear (design pass
/// spec §5).
enum NowRoute: Hashable, CaseIterable {
    case settings
}

/// The Now tab (design pass spec §4 N1–N5): a line with the date and the
/// Mac's status, the next meeting with Record, Waiting for you across every
/// workbench as one card of flat rows, and the session summary on one
/// wrapping line. A `ScrollView`, so each ask row is its own link.
struct NowView: View {
    @Environment(AppEnvironment.self) private var env

    private var replica: WorkbenchReplicaModel { env.workbenchReplica }

    var body: some View {
        NavigationStack {
            // The Mac's status turns offline by the clock alone, and ages tick.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(NowModel(snapshot: replica.snapshot, now: context.date), date: context.date)
            }
            .navigationTitle("Now")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: NowRoute.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .hubSwitcher()
            .navigationDestination(for: NowRoute.self) { _ in SettingsView() }
            .navigationDestination(for: String.self) { EventDetailView(eventID: $0) }
            // An event detail pushed here opens its recap here (Open recap).
            .navigationDestination(for: CalendarRoute.self) { route in
                switch route {
                case let .event(id): EventDetailView(eventID: id)
                case .recordings: RecordingsListView()
                case let .recap(id): RecapView(transcriptID: id)
                }
            }
            .navigationDestination(for: AskRoute.self) { route in
                AskView(replica: replica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: route.id)
            }
            .refreshable { await env.refresh(.pull) }
        }
    }

    private func content(_ model: NowModel, date: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                statusLine(model, date: date)
                if let next = NextMeetingCardModel(events: env.calendarReplica.snapshot.events, now: date, calendar: .current) {
                    NextMeetingCardView(card: next)
                        .padding(.horizontal, Spacing.large)
                        .padding(.top, Spacing.medium)
                }
                SectionHeader("Waiting for you", tone: model.waitingHeaderTone)
                waiting(model)
                SectionHeader("Sessions")
                sessions(model)
            }
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
    }

    /// N1: the date on the left, the Mac's status dot and text on the right,
    /// with no card or capsule.
    private func statusLine(_ model: NowModel, date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.regular)
            HStack(spacing: 5) {
                Circle().fill(model.macChipTone.color).frame(width: 7, height: 7)
                Text(model.macChip).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.top, Spacing.small)
    }

    /// N4: one waiting card, then "N more on your Mac".
    @ViewBuilder
    private func waiting(_ model: NowModel) -> some View {
        if let empty = model.emptyText {
            Text(empty)
                .font(TypeScale.rowTitle)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.large)
        } else {
            WaitingStack(asks: model.waiting)
                .padding(.horizontal, Spacing.large)
            if model.waitingMore > 0 {
                Text("\(model.waitingMore) more on your Mac")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.compact)
            }
        }
    }

    /// N5: the counts wrap and never stack one per line.
    private func sessions(_ model: NowModel) -> some View {
        Group {
            if model.sessionChips.isEmpty {
                Text("No sessions running").font(TypeScale.rowTitle).foregroundStyle(.secondary)
            } else {
                FlowRow {
                    ForEach(model.sessionChips) { SessionCountLabel(count: $0) }
                }
            }
        }
        .padding(.horizontal, Spacing.large)
    }
}

/// N3: "Next · in 25 min", the title, "14:00–14:45 · 5 people · prep ready"
/// and Record, in a plain card; tap the text for the event.
private struct NextMeetingCardView: View {
    @Environment(AppEnvironment.self) private var env
    let card: NextMeetingCardModel

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            NavigationLink(value: card.id) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(card.header).font(TypeScale.meta).foregroundStyle(PhoneTone.accent.color)
                    Text(card.title).font(TypeScale.rowEmphasis).foregroundStyle(.primary)
                    Text(card.line).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RecordButton {
                Task { await env.recorder.recordMeeting(card.meetingEvent) }
            }
            .disabled(!env.canStartCapture)
        }
        .card(.plain)
    }
}
