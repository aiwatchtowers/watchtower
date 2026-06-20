import SwiftUI

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
    @Environment(AppState.self) private var appState

    @State private var comment: String = ""

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

                ForEach(refs) { ref in
                    Button {
                        navigate(to: ref)
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
                                Text(areaLabel(ref.area))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sourceColor(ref.area).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
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
                    Button("1 hour")        { snooze(hours: 1) }
                    Button("Till tomorrow") { snooze(days: 1) }
                    Button("Next week")     { snooze(days: 7) }
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

    // MARK: - Source navigation

    // Ref areas are persisted plural by the Go pipeline (digests/tracks/inbox/
    // briefings); these switches must match that contract or source rows fall to
    // the default branch (broken navigation + generic label/icon).
    private func navigate(to ref: CatchUpRef) {
        switch ref.area {
        case "digests":
            appState.navigateToDigest(ref.id)
        case "tracks":
            appState.navigateToTrack(ref.id)
        case "briefings":
            appState.navigateToBriefing(ref.id)
        case "inbox":
            appState.selectedDestination = .inbox
        default:
            break
        }
    }

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
