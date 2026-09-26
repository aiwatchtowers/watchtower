import SwiftUI
import WatchtowerCore

// MARK: - Source refs
//
// Every claim in a recap carries the rows it was built from (CATCHUP-04 keeps
// invented ones out). These render that provenance: a compact row per ref that
// expands, in place, into a read-only view of the underlying source.

/// The list of sources under a topic / decision / meeting / needs-you item.
struct CatchUpRefList: View {
    let refs: [CatchUpRef]
    let vm: CatchUpViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(refs, id: \.compositeID) { ref in
                CatchUpSourceCard(ref: ref, vm: vm)
            }
        }
    }
}

/// One source row plus its inline expansion. The area→view mapping lives here,
/// covering every area the Go gather emits (`internal/db/catchup.go`).
struct CatchUpSourceCard: View {
    let ref: CatchUpRef
    let vm: CatchUpViewModel
    @Environment(AppState.self) private var appState

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                detail
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(ref.area))
                        .font(.caption)
                        .foregroundStyle(Self.color(ref.area))
                        .frame(width: 18)
                    Text(ref.label.isEmpty ? "\(Self.areaLabel(ref.area)) #\(ref.id)" : ref.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(Self.areaLabel(ref.area))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Outside the expand Button — a nested control inside its label would
            // never receive the click.
            if let destination = Self.destination(ref.area) {
                Button("Open") { appState.selectedDestination = destination }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Open the \(destination.title) tab")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.color(ref.area).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var detail: some View {
        switch ref.area {
        case "digests":
            resolved(vm.digest(byID: ref.id)) { DigestInlineDetail(digest: $0) }
        case "tracks":
            resolved(vm.track(byID: ref.id)) { TrackInlineDetail(track: $0) }
        case "streams":
            resolved(vm.streamDigest(byID: ref.id)) { StreamDigestInline(digest: $0) }
        case "recaps":
            resolved(vm.meetingRecap(byID: ref.id)) {
                MeetingRecapInline(title: fallbackTitle("Meeting"), content: $0.parsed)
            }
        case "transcripts":
            resolved(vm.transcript(byID: ref.id)) {
                MeetingRecapInline(title: $0.title, content: $0.parsedSummary)
            }
        case "decisions":
            resolved(vm.decision(byID: ref.id)) { DecisionInline(idea: $0.idea, mentions: $0.mentions) }
        case "inbox":
            resolved(vm.inboxItem(byID: ref.id)) {
                InboxItemInline(
                    item: $0,
                    origin: vm.inboxOrigin($0),
                    url: CatchUpViewModel.slackMessageURL(for: $0)
                )
            }
        case "targets":
            resolved(vm.target(byID: ref.id)) { TargetInline(target: $0) }
        default:
            missingNotice
        }
    }

    /// Renders `content` for a source that still exists, and the "gone" notice
    /// for one that was pruned or deleted since the recap was composed.
    @ViewBuilder
    private func resolved<T>(_ source: T?, @ViewBuilder content: (T) -> some View) -> some View {
        if let source {
            content(source)
        } else {
            missingNotice
        }
    }

    private var missingNotice: some View {
        Text("Source no longer available")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private func fallbackTitle(_ placeholder: String) -> String {
        ref.label.isEmpty ? placeholder : ref.label
    }

    // MARK: - Area presentation
    //
    // Areas are persisted plural by the Go gather; these three switches and the
    // `detail` switch above cover the same eight values and must stay in sync.

    private static func areaLabel(_ area: String) -> String {
        switch area {
        case "digests": "Digest"
        case "streams": "Mail/Jira"
        case "recaps", "transcripts": "Meeting"
        case "decisions": "Decision"
        case "inbox": "Inbox"
        case "tracks": "Track"
        case "targets": "Target"
        default: area.capitalized
        }
    }

    private static func symbol(_ area: String) -> String {
        switch area {
        case "digests": "doc.text"
        case "streams": "envelope"
        case "recaps", "transcripts": "person.2"
        case "decisions": "arrow.triangle.branch"
        case "inbox": "tray"
        case "tracks": "point.topleft.down.curvedto.point.bottomright.up"
        case "targets": "scope"
        default: "circle"
        }
    }

    private static func color(_ area: String) -> Color {
        switch area {
        case "digests": .blue
        case "streams": .teal
        case "recaps", "transcripts": .indigo
        case "decisions": .orange
        case "inbox": .green
        case "tracks": .purple
        case "targets": .pink
        default: .secondary
        }
    }

    /// The tab a source can be opened in, for the three areas that have one.
    /// The rest are fully rendered inline, so sending the reader away would only
    /// cost them their place.
    private static func destination(_ area: String) -> SidebarDestination? {
        switch area {
        case "inbox": .inbox
        case "tracks": .tracks
        case "targets": .targets
        default: nil
        }
    }
}
