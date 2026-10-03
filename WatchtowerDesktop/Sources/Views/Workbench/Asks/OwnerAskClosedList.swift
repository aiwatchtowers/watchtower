import SwiftUI
import WatchtowerCore

/// "▸ N closed" on a session row (or for the asks filed outside the app):
/// opens the read-only list of its answered, delivered and withdrawn asks.
struct OwnerAskClosedButton: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64?
    let count: Int
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Text("▸ \(count) closed").font(.caption2)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Show the closed asks")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            OwnerAskClosedList(vm: vm, projectID: projectID, sessionID: sessionID) { showing = false }
        }
    }
}

/// A session's closed asks, newest first, each with what became of it
/// ("Answered", "withdrawn by the agent", "replaced by #N"). A click opens
/// it read-only in the drawer.
struct OwnerAskClosedList: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64?
    let dismiss: () -> Void

    private var key: OwnerAsksViewModel.ClosedListKey { .init(projectID: projectID, sessionID: sessionID) }

    var body: some View {
        let asks = vm.asks
        VStack(alignment: .leading, spacing: 6) {
            Text("Closed asks").font(.headline)
            if let error = asks.closedErrors[key] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let list = asks.closedLists[key] {
                if list.isEmpty {
                    Text("No closed asks").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(list) { ask in
                            row(ask, replacedBy: asks.replacements[projectID]?[ask.id])
                        }
                    }
                }
            } else if asks.closedErrors[key] == nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .frame(maxHeight: 360)
        .task { await asks.loadClosed(projectID: projectID, sessionID: sessionID) }
    }

    private func row(_ ask: OwnerAsk, replacedBy: Int64?) -> some View {
        Button {
            dismiss()
            Task { await vm.showAsk(ask.id, projectID: projectID) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: OwnerAskPresentation.askKindIcon(ask.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityLabel(OwnerAskPresentation.askKindLabel(ask.kind))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ask.title).lineLimit(1).truncationMode(.tail)
                    Text(caption(ask, replacedBy: replacedBy))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func caption(_ ask: OwnerAsk, replacedBy: Int64?) -> String {
        let status = OwnerAskPresentation.askStatusLine(ask, replacedBy: replacedBy)
        let age = TimeFormatting.shortAge(from: ask.createdAt, now: Date())
        return [status, age].compactMap(\.self).joined(separator: " · ")
    }
}
