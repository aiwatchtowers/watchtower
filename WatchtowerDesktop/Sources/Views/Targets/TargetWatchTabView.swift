import SwiftUI
import WatchtowerCore

/// The target's "Watch" tab: manage the watches linked to this goal and read
/// their merged activity feed. Applying an event's proposed action mutates the
/// target; "Discuss" pushes it into the target Assistant.
struct TargetWatchTabView: View {
    let viewModel: TargetWatchesViewModel
    /// Called with a seed prompt when the user taps Discuss on an event.
    var onDiscuss: (String) -> Void

    @Environment(AppState.self) private var appState
    @State private var showAddWatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            managementStrip
            Divider()
            feed
        }
        .padding()
        .sheet(isPresented: $showAddWatch) {
            CustomTrackManagementSheet(linkedTargetID: viewModel.target.id)
        }
    }

    private var managementStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Watches", systemImage: "binoculars").font(.headline)
                Spacer()
                Button { Task { await viewModel.scanAll() } } label: {
                    Label("Scan all", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(viewModel.watches.isEmpty)
                Button { showAddWatch = true } label: {
                    Label("Watch", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if viewModel.watches.isEmpty {
                Text("No watches yet — add a watch to track activity for this goal.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.watches) { watch in watchRow(watch) }
            }
            if let origin = viewModel.originTrack {
                Button { appState.navigateToTrack(origin.id) } label: {
                    Label("From track: \(origin.text)", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private func watchRow(_ watch: Track) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { watch.enabled },
                set: { viewModel.setCollecting(watch, $0) }
            )) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(watch.enabled ? "Collecting" : "Paused")

            Text(watch.text).font(.subheadline).lineLimit(1)
            Spacer()
            if viewModel.isScanning(watch.id) {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Since last check") { Task { await viewModel.scanWatch(watch, since: nil, label: "since last check") } }
                Button("Last 7 days") { scan(watch, days: 7) }
                Button("Last 30 days") { scan(watch, days: 30) }
                Button("Last 90 days") { scan(watch, days: 90) }
                Button("All history") { Task { await viewModel.scanWatch(watch, since: nil, label: "all history") } }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(viewModel.isScanning(watch.id))

            Button(role: .destructive) { viewModel.deleteWatch(watch) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func scan(_ watch: Track, days: Int) {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        Task { await viewModel.scanWatch(watch, since: since, label: "last \(days) days") }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            if viewModel.events.isEmpty {
                Text("No activity yet. Scan a watch to backfill, or wait for the next daemon cycle.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    TargetWatchEventRow(event: event, viewModel: viewModel, onDiscuss: onDiscuss)
                        .onAppear { viewModel.markRead(event) }
                }
            }
        }
    }
}

/// One feed event: source watch + summary, confirmable target action, Discuss.
private struct TargetWatchEventRow: View {
    let event: TrackEvent
    let viewModel: TargetWatchesViewModel
    var onDiscuss: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if event.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.watchName(for: event.trackId).uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(event.summary).font(.body)
                    if expanded, !event.detail.isEmpty {
                        Text(event.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .buttonStyle(.plain)
            }

            if event.actionStatus == "pending", let action = event.decodedAction {
                HStack(spacing: 8) {
                    Text(action.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Apply") { viewModel.applyAction(for: event) }.controlSize(.small)
                    Button("Dismiss") { viewModel.dismissAction(for: event) }
                        .controlSize(.small).buttonStyle(.borderless)
                }
            } else if event.actionStatus == "applied" {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button {
                    onDiscuss("Regarding this watch update: \"\(event.summary)\". How should this change the target?")
                } label: {
                    Label("Discuss", systemImage: "text.bubble").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Divider()
        }
        .padding(.vertical, 2)
    }
}
