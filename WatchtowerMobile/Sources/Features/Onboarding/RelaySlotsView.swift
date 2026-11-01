import SwiftUI

/// The three-slots screen (`RelaySlotsModel`): inline on the link screen before the owner confirmed the code, or
/// from a finishing link's **Manage Macs** in Settings → Macs. Remove asks first (an unlink, or a finishing link's
/// cancel), shows "Removing…" with the other rows disabled, and a failure turns the title and the row's action into
/// "Try Again". After a removal the link goes on by itself.
struct RelaySlotsView: View {
    @Environment(LinkingViewModel.self) private var linking
    @Environment(\.dynamicTypeSize) private var typeSize
    let onClose: () -> Void
    @State private var asking: RelaySlotsModel.Ask?

    /// `asking`: a Remove's confirmation already open (the screenshot tour's frame).
    init(asking: RelaySlotsModel.Ask? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _asking = State(initialValue: asking)
    }

    var body: some View {
        let model = RelaySlotsModel(state: linking.relaySlots, links: linking.links, promoted: linking.promotedLinks)
        NavigationStack {
            List {
                Section {
                    Text(model.title)
                        .font(TypeScale.rowTitle)
                        .macsListRow()
                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .macsListRow()
                    }
                    ForEach(model.rows) { row in
                        slotRow(row)
                            .macsListRow()
                    }
                    Text(model.footnote)
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .macsListRow()
                }
            }
            .macsList()
            .navigationTitle(RelaySlotsModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(RelaySlotsModel.cancelTitle, action: onClose)
                        .disabled(linking.relaySlots.removing != nil)
                }
            }
        }
        .confirmationDialog(
            asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            titleVisibility: .visible, presenting: asking
        ) { ask in
            Button(ask.confirm, role: .destructive) {
                Task { await linking.removeFromSlots(ask.mac) }
            }
            Button(ask.keep, role: .cancel) {}
        } message: { ask in
            if let message = ask.message {
                Text(message)
            }
        }
    }

    /// At the accessibility text sizes the action goes under the name, which then wraps instead of truncating.
    @ViewBuilder private func slotRow(_ row: RelaySlotsModel.Row) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                FlatRow(icon: .symbol("laptopcomputer", tone: .secondary), title: row.name, titleLineLimit: 3, insets: EdgeInsets()) {
                    if let sub = row.sub {
                        Text(sub)
                    }
                }
                slotAction(row)
            }
        } else {
            FlatRow(icon: .symbol("laptopcomputer", tone: .secondary), title: row.name, titleLineLimit: 1, insets: EdgeInsets()) {
                if let sub = row.sub {
                    Text(sub)
                }
            } trailing: {
                slotAction(row)
            }
        }
    }

    @ViewBuilder private func slotAction(_ row: RelaySlotsModel.Row) -> some View {
        if row.action == .removing {
            HStack(spacing: Spacing.compact) {
                Text(row.action.title)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                ProgressView()
            }
        } else {
            Button(row.action.title) {
                if let ask = RelaySlotsModel.ask(for: row) {
                    asking = ask
                } else {
                    Task { await linking.removeFromSlots(row.id) }
                }
            }
            .buttonStyle(BannerButtonStyle())
            .disabled(row.isDisabled)
        }
    }
}
