import SwiftUI

/// The scan-produced activity timeline shown on a CUSTOM track's detail page.
/// Ported from the removed `ObserverTimelineView`. A custom track carries a
/// single watch instruction (not N observers), so the observer-chip UI is gone;
/// the refresh + history-scan controls remain. A confirmable proposed action is
/// only actionable when the track is linked to a target (`canApplyActions`).
struct CustomTrackTimelineView: View {
    let viewModel: CustomTrackTimelineViewModel
    @State private var showScanPopover = false
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
                Text(viewModel.lastScannedText)
                    .font(.caption2).foregroundStyle(.secondary)
                if viewModel.isScanRunning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    showScanPopover = true
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(viewModel.isScanRunning)
                .help("Scan a chosen range and fill the timeline")
                .popover(isPresented: $showScanPopover, arrowEdge: .bottom) { scanRangePopover }
            }

            if viewModel.isScanRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.scanStatus ?? "Scanning… you can leave this view; it keeps running.")
                        .font(.caption).foregroundColor(.secondary)
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
            } else if let note = viewModel.lastScanNote {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundColor(.secondary)
                    Text(note).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    Spacer()
                    Button { viewModel.lastScanNote = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            if viewModel.events.isEmpty {
                Text("No activity yet. This track surfaces relevant updates as they happen — or scan history to backfill.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    TrackEventRow(event: event, viewModel: viewModel)
                        .onAppear { viewModel.markRead(event) }
                }
            }
        }
    }

    private var unreadCount: Int { viewModel.events.filter { $0.isUnread }.count }

    private func scanHistory(days: Int) {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        Task { await viewModel.scanHistory(since: since, label: "last \(days) days") }
    }

    /// A tappable range option that dismisses the popover and kicks off the scan.
    private func rangeRow(_ title: String, systemImage: String, _ run: @escaping () -> Void) -> some View {
        Button {
            showScanPopover = false
            run()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The "choose a period" popover. Every option builds on what's already
    /// collected — it reads only what's newer than the range start and dedups
    /// against existing events, so nothing is duplicated.
    private var scanRangePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan range").font(.headline)
            Text("Reads what's new for the chosen range and dedups against what the track already collected.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            rangeRow("Since last check", systemImage: "arrow.clockwise") {
                Task { await viewModel.scanSinceLast() }
            }
            rangeRow("Last 7 days", systemImage: "calendar") { scanHistory(days: 7) }
            rangeRow("Last 30 days", systemImage: "calendar") { scanHistory(days: 30) }
            rangeRow("Last 90 days", systemImage: "calendar") { scanHistory(days: 90) }
            rangeRow("Since track created", systemImage: "flag") {
                Task { await viewModel.scanHistory(since: viewModel.track.createdDate, label: "since the track was created") }
            }
            rangeRow("All history", systemImage: "infinity") {
                Task { await viewModel.scanHistory(since: nil, label: "all history") }
            }

            Divider()
            Text("From a specific date").font(.caption).foregroundColor(.secondary)
            DatePicker("", selection: $customSince, in: ...Date(), displayedComponents: [.date])
                .datePickerStyle(.compact).labelsHidden()
            Button("Scan from date") {
                showScanPopover = false
                let label = "from " + customSince.formatted(date: .abbreviated, time: .omitted)
                Task { await viewModel.scanHistory(since: customSince, label: label) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 300)
    }
}

private struct TrackEventRow: View {
    let event: TrackEvent
    let viewModel: CustomTrackTimelineViewModel
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
                    // Only a track linked to a target can apply a proposed action.
                    if viewModel.canApplyActions {
                        Button("Apply") { viewModel.applyAction(for: event) }
                            .controlSize(.small)
                    }
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
