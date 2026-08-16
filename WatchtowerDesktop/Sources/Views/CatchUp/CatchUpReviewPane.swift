import SwiftUI
import WatchtowerCore

// MARK: - CatchUpReviewPane
//
// The rich single-theme review screen on the right of the two-panel UX. Shows
// the theme's title, priority / needs-you badges, narrative, a Sources block
// that navigates to the underlying digest/track/inbox/briefing, the suggested
// action, and a bottom action bar (👍/👎 + comment field, Regenerate, Create
// task, Snooze, Done). All mutating actions are delegated to the ViewModel.
struct CatchUpReviewPane: View {
    let theme: CatchUpTheme
    let vm: CatchUpViewModel
    /// Invoked when the operator taps a source row. The parent decides whether to
    /// open it inline (a sheet over Catch-Up, for digests/tracks) or to switch the
    /// sidebar destination (briefings/inbox) — keeping the area→behaviour mapping
    /// in one place.
    var onOpenSource: (CatchUpRef) -> Void

    @State private var comment: String = ""
    /// Source rows (digests/tracks) the operator has expanded inline, keyed by
    /// `CatchUpRef.compositeID`. Reset per theme via the `.id(theme.id)` below.
    @State private var expandedSources: Set<String> = []
    /// Per-source dates + external links, keyed by `CatchUpRef.compositeID`.
    /// Loaded by the `.task` below; keyed on `theme.refs` (not `theme.id`) so
    /// the refs filling in when expansion completes re-fetches it.
    @State private var sourceMeta: [String: CatchUpSourceMeta] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if theme.isFailed {
                        failedNotice
                    }
                    if !theme.narrative.isEmpty {
                        Text(theme.narrative)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if theme.isExpanding {
                        expandingNotice
                    }
                    suggestedActionSection
                    sourcesSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            actionBar
        }
        // Reset the comment field when switching to a different theme.
        .id(theme.id)
        .task(id: theme.refs) {
            sourceMeta = await vm.sourceMeta(for: theme.decodedRefs)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                priorityBadge
                if theme.needsYou {
                    Label("Needs you", systemImage: "person.fill.questionmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                if theme.isReviewed {
                    Label("Reviewed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.12), in: Capsule())
                }
                Spacer()
                if theme.taskID > 0 {
                    Label("Task", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Text(theme.title.isEmpty ? "Untitled theme" : theme.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            activityLine
        }
    }

    /// The span of the underlying sources' own timestamps — when this actually
    /// happened. The theme row's created_at only says when the session was
    /// built, which loses the operator's sense of time and urgency.
    @ViewBuilder
    private var activityLine: some View {
        let dates = theme.decodedRefs.compactMap { sourceMeta[$0.compositeID]?.date }
        if let latest = dates.max() {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                if let earliest = dates.min(), !Calendar.current.isDate(earliest, inSameDayAs: latest) {
                    Text("\(TimeFormatting.shortDateTime(from: earliest)) – \(TimeFormatting.shortDateTime(from: latest))")
                } else {
                    Text(TimeFormatting.shortDateTime(from: latest))
                }
                Text("· \(TimeFormatting.relativeTime(from: latest))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var priorityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
            Text(theme.priority.capitalized)
                .font(.caption)
                .foregroundStyle(priorityColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(priorityColor.opacity(0.1), in: Capsule())
    }

    // MARK: - Notices

    private var expandingNotice: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Assembling this theme…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var failedNotice: some View {
        Label(
            "This theme failed to assemble. Use Regenerate to retry.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Suggested action

    @ViewBuilder
    private var suggestedActionSection: some View {
        if !theme.suggestedAction.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .font(.callout)
                Text(theme.suggestedAction)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        let refs = theme.decodedRefs
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources")
                    .font(.headline)

                ForEach(refs, id: \.compositeID) { ref in
                    sourceRow(ref)
                }
            }
        }
    }

    /// A tappable source row plus, for digests/tracks, its inline detail expanded
    /// underneath. Briefings/inbox have no inline renderer, so their row navigates
    /// away via `onOpenSource`.
    @ViewBuilder
    private func sourceRow(_ ref: CatchUpRef) -> some View {
        let expandable = isExpandable(ref.area)
        let expanded = expandedSources.contains(ref.compositeID)
        let meta = sourceMeta[ref.compositeID]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    tapSource(ref)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sourceSymbol(ref.area))
                            .font(.caption)
                            .foregroundStyle(sourceColor(ref.area))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.label.isEmpty ? "\(areaLabel(ref.area)) #\(ref.id)" : ref.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                Text(areaLabel(ref.area))
                                if let date = meta?.date {
                                    Text("· \(TimeFormatting.shortDateTime(from: date))")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Chevron points down/up for the inline-expandable areas, right
                        // for the navigate-away ones.
                        Image(systemName: expandable ? (expanded ? "chevron.up" : "chevron.down") : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Outside the expand/navigate Button — a Link nested inside its
                // label would never receive the click.
                if let url = meta?.url {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("Open in Slack")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sourceColor(ref.area).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if expandable && expanded {
                sourceExpansion(for: ref)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func sourceExpansion(for ref: CatchUpRef) -> some View {
        switch ref.area {
        case "digests":
            if let digest = vm.digest(byID: ref.id) {
                DigestInlineDetail(digest: digest)
            } else {
                sourceMissingNotice
            }
        case "tracks":
            if let track = vm.track(byID: ref.id) {
                TrackInlineDetail(track: track)
            } else {
                sourceMissingNotice
            }
        default:
            EmptyView()
        }
    }

    private var sourceMissingNotice: some View {
        Text("This source is no longer available.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private func isExpandable(_ area: String) -> Bool {
        area == "digests" || area == "tracks"
    }

    private func tapSource(_ ref: CatchUpRef) {
        guard isExpandable(ref.area) else {
            onOpenSource(ref)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedSources.contains(ref.compositeID) {
                expandedSources.remove(ref.compositeID)
            } else {
                expandedSources.insert(ref.compositeID)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    vm.submitFeedback(theme, rating: 1, comment: comment)
                    comment = ""
                } label: {
                    Image(systemName: "hand.thumbsup")
                }
                .buttonStyle(.bordered)
                .help("Helpful")

                Button {
                    vm.submitFeedback(theme, rating: -1, comment: comment)
                    comment = ""
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .buttonStyle(.bordered)
                .help("Not helpful")

                TextField("Comment to teach the system or correct this theme…", text: $comment)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button {
                    vm.regenerate(theme, comment: comment)
                    comment = ""
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                if theme.taskID == 0 {
                    Button {
                        Task { await vm.createTask(theme) }
                    } label: {
                        Label("Create task", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                }

                Menu {
                    Button("1 hour") { snooze(hours: 1) }
                    Button("Till tomorrow") { snooze(days: 1) }
                    Button("Next week") { snooze(days: 7) }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    Task { await vm.acknowledge(theme) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
    }

    // MARK: - Snooze helpers

    private func snooze(hours: Int) {
        let until = Calendar.current.date(byAdding: .hour, value: hours, to: Date()) ?? Date()
        Task { await vm.snooze(theme, until: until) }
    }

    private func snooze(days: Int) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        Task { await vm.snooze(theme, until: until) }
    }

    // MARK: - Source area presentation

    // Ref areas are persisted plural by the Go pipeline (digests/tracks/inbox/
    // briefings). The parent's `onOpenSource` handler routes on these; the
    // label/icon helpers below switch on the same set and must stay in sync.
    private func areaLabel(_ area: String) -> String {
        switch area {
        case "digests": return "Digest"
        case "tracks": return "Track"
        case "inbox": return "Inbox"
        case "briefings": return "Briefing"
        default: return area.capitalized
        }
    }

    private func sourceSymbol(_ area: String) -> String {
        switch area {
        case "digests": return "doc.text"
        case "tracks": return "point.topleft.down.curvedto.point.bottomright.up"
        case "inbox": return "tray"
        case "briefings": return "sun.max"
        default: return "circle"
        }
    }

    private func sourceColor(_ area: String) -> Color {
        switch area {
        case "digests": return .blue
        case "tracks": return .purple
        case "inbox": return .green
        case "briefings": return .yellow
        default: return .secondary
        }
    }

    // MARK: - Priority

    private var priorityColor: Color {
        switch theme.priority {
        case "high": return .red
        case "low": return .blue
        default: return .orange
        }
    }
}
