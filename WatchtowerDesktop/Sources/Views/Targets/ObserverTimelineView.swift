import SwiftUI

/// The observer-produced activity timeline shown on a target's detail page.
struct ObserverTimelineView: View {
    @State var viewModel: ObserverTimelineViewModel
    @State private var showingManage = false
    @State private var showingCustom = false
    @State private var customSince = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.headline)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                Spacer()
                Button { Task { await viewModel.refreshNow() } } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRefreshing)
                Menu {
                    Button("Last 7 days") { scanHistory(days: 7) }
                    Button("Last 30 days") { scanHistory(days: 30) }
                    Button("Last 90 days") { scanHistory(days: 90) }
                    Button("Since target start") {
                        Task { await viewModel.scanHistory(since: viewModel.target.createdDate, label: "since target start") }
                    }
                    Button("All history") {
                        Task { await viewModel.scanHistory(since: nil, label: "all history") }
                    }
                    Divider()
                    Button("Custom…") { showingCustom = true }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(viewModel.isRefreshing)
                .help("Scan history and fill the timeline")
                .popover(isPresented: $showingCustom, arrowEdge: .bottom) { customScanPopover }
                Button { showingManage = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
            }

            observerChips

            if let status = viewModel.scanStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            } else if let err = viewModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    Spacer()
                    Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            if viewModel.events.isEmpty {
                if viewModel.observers.isEmpty {
                    Text("No observers yet — tap + to watch this goal.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("No activity yet. Observers will surface relevant updates as they happen.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                ForEach(viewModel.events) { event in
                    ObserverEventRow(event: event, viewModel: viewModel)
                        .onAppear { viewModel.markRead(event) }
                }
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: $showingManage) {
            ObserverManagementSheet(viewModel: viewModel)
        }
    }

    private var unreadCount: Int { viewModel.events.filter { $0.isUnread }.count }

    private func scanHistory(days: Int) {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        Task { await viewModel.scanHistory(since: since, label: "last \(days) days") }
    }

    /// Date picker for a custom "scan from" instant. Restricted to the past —
    /// there is no activity to scan in the future.
    private var customScanPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan history from").font(.headline)
            DatePicker("", selection: $customSince, in: ...Date(),
                       displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { showingCustom = false }
                Button("Scan") {
                    showingCustom = false
                    let label = "from " + customSince.formatted(date: .abbreviated, time: .omitted)
                    Task { await viewModel.scanHistory(since: customSince, label: label) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }

    /// Always-visible row of observer chips (name + enabled dot) plus an add
    /// affordance, so the user can see and reach their observers without opening
    /// the management sheet. Tapping a chip or "+" opens that sheet.
    private var observerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.observers) { observer in
                    Button { showingManage = true } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(observer.enabled ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(observer.name).font(.caption).lineLimit(1)
                        }
                        .observerChipBackground()
                    }
                    .buttonStyle(.plain)
                }
                Button { showingManage = true } label: {
                    Image(systemName: "plus").font(.caption)
                        .observerChipBackground()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private extension View {
    func observerChipBackground() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct ObserverEventRow: View {
    let event: ObserverEvent
    let viewModel: ObserverTimelineViewModel
    @State private var expanded = false
    @State private var sourceURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Tappable header — click anywhere on the summary row to expand/collapse.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    if event.isUnread {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 6)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary).font(.body).multilineTextAlignment(.leading)
                        if !expanded, !event.detail.isEmpty {
                            Text(event.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                expandedContent
                    .task(id: expanded) { sourceURL = viewModel.sourceLink(for: event) }
            } else {
                metaLine
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

    /// Collapsed footer: source kind + decision chip on a single line.
    private var metaLine: some View {
        HStack(spacing: 6) {
            if !event.sourceType.isEmpty {
                Text(event.sourceType.uppercased()).font(.caption2).foregroundColor(.secondary)
            }
            if let decision = event.decodedDecisionText {
                Label(decision, systemImage: "checkmark.seal")
                    .font(.caption2).foregroundColor(.orange).lineLimit(1)
            }
        }
        .padding(.leading, event.isUnread ? 12 : 0)
    }

    /// Expanded body: full detail, decision, clickable source links, and meta.
    private var expandedContent: some View {
        let refs = event.decodedRefs
        return VStack(alignment: .leading, spacing: 6) {
            if !event.detail.isEmpty {
                Text(event.detail).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let decision = event.decodedDecisionText {
                Label(decision, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !refs.isEmpty {
                ForEach(Array(refs.enumerated()), id: \.offset) { idx, ref in
                    if let url = URL(string: ref) {
                        Link(destination: url) {
                            Label(refs.count > 1 ? "Open source \(idx + 1)" : "Open source",
                                  systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                }
            } else if let sourceURL, let url = URL(string: sourceURL) {
                Link(destination: url) {
                    Label(event.sourceType == "inbox" ? "Open in Slack" : "Open source",
                          systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            } else {
                Text("No linked source").font(.caption2).foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                if !event.sourceType.isEmpty {
                    Text(event.sourceType.uppercased()).font(.caption2).foregroundColor(.secondary)
                }
                if !event.sourceId.isEmpty {
                    Text("#\(event.sourceId)").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Text(Self.prettyDate(event.createdAt)).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.leading, event.isUnread ? 12 : 0)
    }

    /// Renders the stored ISO8601 created_at as a short, human date+time.
    private static func prettyDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
