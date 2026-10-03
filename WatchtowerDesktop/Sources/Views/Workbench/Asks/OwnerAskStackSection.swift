import SwiftUI
import WatchtowerCore

/// The top of the session panel (spec 2026-10-03 Part 8): "Waiting for you
/// (N)", every open ask of the workbench oldest first — kind, title,
/// session and age. A click puts the ask's session on screen and opens the
/// drawer on it (`WorkbenchesViewModel.showAsk`). The closed asks filed
/// from outside the app have no session row: their "N closed" sits here.
struct OwnerAskStackSection: View {
    /// Past this the rows scroll, so a long stack never pushes the
    /// session list off the panel.
    static let maxRowsHeight: CGFloat = 220

    let vm: WorkbenchesViewModel
    let project: Workbench
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        let asks = vm.asks
        let stack = asks.stack(projectID: project.id)
        let outsideClosed = asks.closedCounts[project.id]?[nil] ?? 0
        if !stack.asks.isEmpty || outsideClosed > 0 || asks.loadErrors[project.id] != nil {
            VStack(alignment: .leading, spacing: 2) {
                if !stack.asks.isEmpty {
                    Text("Waiting for you (\(stack.count))")
                        .sidebarSectionLabel()
                        .padding(.horizontal, 12)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(stack.asks) { ask in
                                OwnerAskStackRow(
                                    ask: ask,
                                    sessionTitle: sessionTitle(ask),
                                    isSelected: asks.drawerAskIDs[project.id] == ask.id
                                ) {
                                    Task { await vm.showAsk(ask.id, projectID: project.id) }
                                }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { rowsHeight = $0 })
                    }
                    .frame(height: min(rowsHeight, Self.maxRowsHeight))
                }
                if outsideClosed > 0 {
                    HStack(spacing: 4) {
                        Text(OwnerAskStack.outsideTheAppTitle).font(.caption2).foregroundStyle(.secondary)
                        OwnerAskClosedButton(vm: vm, projectID: project.id, sessionID: nil, count: outsideClosed)
                    }
                    .padding(.horizontal, 12)
                }
                if let error = asks.loadErrors[project.id] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    private func sessionTitle(_ ask: OwnerAsk) -> String {
        guard let id = ask.sessionID else { return OwnerAskStack.outsideTheAppTitle }
        return vm.session(id, projectID: project.id)?.title ?? "Session"
    }
}

/// One waiting ask: its kind's icon, title, then session · age.
private struct OwnerAskStackRow: View {
    let ask: OwnerAsk
    let sessionTitle: String
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: OwnerAskPresentation.askKindIcon(ask.kind))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                    .accessibilityLabel(OwnerAskPresentation.askKindLabel(ask.kind))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ask.title).lineLimit(1).truncationMode(.tail)
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(ask.title)
    }

    private var caption: String {
        let age = TimeFormatting.shortAge(from: ask.createdAt, now: Date())
        return [sessionTitle, age].compactMap(\.self).joined(separator: " · ")
    }
}
