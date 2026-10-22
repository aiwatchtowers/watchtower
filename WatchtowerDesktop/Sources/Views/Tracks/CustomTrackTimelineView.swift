import SwiftUI
import WatchtowerCore

/// The scan-produced activity timeline on a CUSTOM track's card: what came
/// in since the owner last looked first, then the read events folded under
/// `Earlier · N` until **Show all**. Opening the card writes nothing (R4);
/// the card's Done marks every event read. **Scan** opens an inline row of
/// ranges (no pop-up); a range from a date scans through the card's seam.
/// A proposed action's **Apply** is offered only on a track linked to a
/// target (`canApplyActions`) and runs the registry press (`TrackActionPress`).
struct CustomTrackTimelineView: View {
    let viewModel: CustomTrackTimelineViewModel
    /// The card owns its inline rows and folds (`TrackCardState`).
    @Binding var scanRowOpen: Bool
    @Binding var showsEarlier: Bool
    @State private var customSince = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            header
            if scanRowOpen {
                scanRow
            }
            status
            timeline
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Text("Activity").font(.headline)
            Spacer()
            Text(viewModel.lastScannedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if viewModel.isScanRunning {
                ProgressView().controlSize(.small)
            }
            Button("Scan") { scanRowOpen.toggle() }
                .buttonStyle(.kitQuiet)
                .controlSize(.small)
                .disabled(viewModel.isScanRunning)
                .help("Scan a chosen range and fill the timeline")
        }
    }

    // MARK: - Events

    @ViewBuilder
    private var timeline: some View {
        let unread = viewModel.events.filter(\.isUnread)
        let earlier = viewModel.events.filter { !$0.isUnread }
        if viewModel.events.isEmpty {
            Text("No activity yet. This track surfaces relevant updates as they happen — or scan history to backfill.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !unread.isEmpty {
            SectionHeader(title: "New since you looked", systemImage: "sparkles")
            rows(unread)
        }
        if !earlier.isEmpty {
            // Nothing new: the earlier events are all there is, so they show.
            let folded = !showsEarlier && !unread.isEmpty
            HStack(spacing: Spacing.regular) {
                SectionHeader(title: "Earlier · \(earlier.count)", systemImage: "clock")
                Spacer()
                if folded {
                    Button("Show all") { showsEarlier = true }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                }
            }
            .padding(.top, unread.isEmpty ? 0 : Spacing.small)
            if !folded {
                rows(earlier)
            }
        }
    }

    private func rows(_ events: [TrackEvent]) -> some View {
        ForEach(events) { event in
            TrackEventRow(event: event, viewModel: viewModel)
        }
    }

    // MARK: - Scan status

    @ViewBuilder
    private var status: some View {
        if viewModel.isScanRunning {
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text(viewModel.scanStatus ?? "Scanning… you can leave this view; it keeps running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(Spacing.regular)
            .card()
        } else if let err = viewModel.errorMessage {
            note(err, systemImage: "exclamationmark.triangle.fill") { viewModel.errorMessage = nil }
        } else if let note = viewModel.lastScanNote {
            self.note(note, systemImage: "checkmark.circle") { viewModel.lastScanNote = nil }
        }
    }

    private func note(_ text: String, systemImage: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.kitIcon(isOn: false))
                .help("Close")
                .accessibilityLabel("Close")
        }
        .padding(Spacing.regular)
        .card()
    }

    // MARK: - The scan row

    /// The ranges to scan, inline. Every option builds on what's already
    /// collected — it reads only what's newer than the range start and dedups
    /// against existing events, so nothing is duplicated.
    private var scanRow: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Scan range").font(.subheadline.weight(.semibold))
            Text("Reads what's new for the chosen range and dedups against what the track already collected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: Spacing.regular) {
                range("Since last check") { await viewModel.scanSinceLast() }
                range("Last 7 days") { await scanHistory(days: 7) }
                range("Last 30 days") { await scanHistory(days: 30) }
                range("Last 90 days") { await scanHistory(days: 90) }
                range("Since track created") {
                    await viewModel.scanHistory(since: viewModel.track.createdDate, label: "since the track was created")
                }
                range("All history") { await viewModel.scanHistory(since: nil, label: "all history") }
            }
            HStack(spacing: Spacing.regular) {
                Text("From").font(.caption).foregroundStyle(.secondary)
                DatePicker("From", selection: $customSince, in: ...Date(), displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                Button("Scan from date") {
                    let since = customSince
                    let label = "from " + since.formatted(date: .abbreviated, time: .omitted)
                    start { await viewModel.scanHistory(since: since, label: label) }
                }
                .buttonStyle(.kitSecondary)
                Spacer()
                Button("Cancel") { scanRowOpen = false }
                    .buttonStyle(.kitQuiet)
            }
        }
        .controlSize(.small)
        .padding(Spacing.medium)
        .card()
    }

    private func range(_ title: String, _ run: @escaping @MainActor () async -> Void) -> some View {
        Button(title) { start(run) }
            .buttonStyle(.kitSecondary)
    }

    /// Closes the row and starts the scan; the status line shows its progress.
    private func start(_ run: @escaping @MainActor () async -> Void) {
        scanRowOpen = false
        Task { await run() }
    }

    private func scanHistory(days: Int) async {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        await viewModel.scanHistory(since: since, label: "last \(days) days")
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
                        Button("Apply") { Task { await viewModel.applyAction(for: event) } }
                            .buttonStyle(.kitSecondary)
                    }
                    Button("Dismiss") { Task { await viewModel.dismissAction(for: event) } }
                        .buttonStyle(.kitQuiet)
                }
                .controlSize(.small)
                .disabled(viewModel.pendingWrites.isPending(event.id))
                .padding(.top, 2)
            } else if event.actionStatus == "applied" {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundColor(.green)
            }
        }
        .padding(.vertical, Spacing.small)
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
