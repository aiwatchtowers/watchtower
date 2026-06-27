import SwiftUI

/// The observer-produced activity timeline shown on a target's detail page.
struct ObserverTimelineView: View {
    @State var viewModel: ObserverTimelineViewModel
    @State private var showingManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.headline)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor).foregroundColor(.white).clipShape(Capsule())
                }
                Spacer()
                Button { Task { await viewModel.refreshNow() } } label: {
                    if viewModel.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRefreshing)
                Button { showingManage = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
            }

            if viewModel.events.isEmpty {
                Text("No activity yet. Observers will surface relevant updates as they happen.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    ObserverEventRow(event: event, viewModel: viewModel)
                        .onAppear { viewModel.markRead(event) }
                }
            }
        }
        .onAppear { viewModel.start() }
        .sheet(isPresented: $showingManage) {
            ObserverManagementSheet(viewModel: viewModel)
        }
    }

    private var unreadCount: Int { viewModel.events.filter { $0.isUnread }.count }
}

private struct ObserverEventRow: View {
    let event: ObserverEvent
    let viewModel: ObserverTimelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if event.isUnread { Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 6) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary).font(.body)
                    if !event.detail.isEmpty {
                        Text(event.detail).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        if !event.sourceType.isEmpty {
                            Text(event.sourceType.uppercased()).font(.caption2).foregroundColor(.secondary)
                        }
                        if let decision = event.decodedDecisionText {
                            Label(decision, systemImage: "checkmark.seal")
                                .font(.caption2).foregroundColor(.orange).lineLimit(1)
                        }
                        ForEach(event.decodedRefs, id: \.self) { ref in
                            if let url = URL(string: ref) {
                                Link(destination: url) { Image(systemName: "link").font(.caption2) }
                            }
                        }
                    }
                }
            }
            if event.actionStatus == "pending", let action = event.decodedAction {
                HStack(spacing: 8) {
                    Text(action.reason).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    Spacer()
                    Button("Apply") { viewModel.applyAction(for: event) }
                        .controlSize(.small)
                    Button("Dismiss") { viewModel.dismissAction(for: event) }
                        .controlSize(.small).buttonStyle(.borderless)
                }
                .padding(.top, 2)
            } else if event.actionStatus == "applied" {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundColor(.green)
            }
            Divider()
        }
        .padding(.vertical, 2)
    }
}
