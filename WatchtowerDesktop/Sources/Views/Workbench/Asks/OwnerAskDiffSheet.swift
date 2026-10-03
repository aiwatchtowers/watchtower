import SwiftUI
import WatchtowerCore

/// "Show diff" of a review re-round (spec 2026-10-03 Part 8): the previous
/// round's snapshot against this one, as a line diff
/// (`OwnerAskSnapshotDiff`, computed off the main actor) with the sections
/// added, removed and changed listed above it.
struct OwnerAskDiffSheet: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading

    private enum Phase {
        case loading
        case failed(String)
        case ready(OwnerAskSnapshotDiff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(ask.previousAskID.map { "Changes since #\($0)" } ?? "Changes").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 640)
        .task(id: ask.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(diff) where diff.isIdentical:
            Text("No changes").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(diff):
            VStack(alignment: .leading, spacing: 0) {
                sections(diff)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in row(line) }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func sections(_ diff: OwnerAskSnapshotDiff) -> some View {
        let groups = [("Added", diff.addedHeadings), ("Removed", diff.removedHeadings), ("Changed", diff.changedHeadings)]
            .filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.0) { title, headings in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(headings.joined(separator: " · ")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            Divider()
        }
    }

    private func row(_ line: OwnerAskSnapshotDiff.Line) -> some View {
        let (mark, text, tint): (String, String, Color?) = switch line {
        case let .same(text): (" ", text, nil)
        case let .added(text): ("+", text, .green)
        case let .removed(text): ("−", text, .red)
        }
        return HStack(alignment: .top, spacing: 8) {
            Text(mark).foregroundStyle(tint ?? .secondary).frame(width: 10)
            Text(text.isEmpty ? " " : text).foregroundStyle(tint == nil ? .secondary : .primary)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { $0.opacity(0.12) } ?? .clear)
        .textSelection(.enabled)
    }

    private func load() async {
        guard let previousID = ask.previousAskID else {
            phase = .failed("This ask has no earlier round.")
            return
        }
        do {
            guard let previous = try await asks.snapshot(askID: previousID, projectID: ask.projectID) else {
                phase = .failed("Ask #\(previousID) no longer exists.")
                return
            }
            let current = ask.docSnapshot
            let diff = await Task.detached(priority: .userInitiated) {
                OwnerAskSnapshotDiff(previous: previous, current: current)
            }.value
            phase = .ready(diff)
        } catch {
            phase = .failed("Could not load ask #\(previousID): \(error.localizedDescription)")
        }
    }
}
