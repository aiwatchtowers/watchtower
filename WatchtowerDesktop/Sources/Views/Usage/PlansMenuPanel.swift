import DesignKit
import SwiftUI
import WatchtowerCore

/// The live menu-bar window and DesignShotCatalog share this card panel.
struct PlansMenuPanel: View {
    let model: PlansPopupPresentation
    @Binding var showInMenuBar: Bool
    let openPlans: () -> Void
    let refresh: (PlanUsageProvider) -> Void
    let refreshAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack {
                Text(PlansPopupCopy.title).font(.headline)
                Spacer()
                Text(model.freshness).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(model.providers) { provider in
                if provider.id.subscription.layout == .compact { claude(provider) } else { codex(provider) }
            }
            HStack {
                Button(PlansScreenCopy.open, action: openPlans).buttonStyle(.kitQuiet)
                Spacer()
                Button(model.refreshTitle, action: refreshAll).buttonStyle(.kitSecondary).disabled(!model.canRefresh)
            }
            Toggle(PlansScreenCopy.menu, isOn: $showInMenuBar)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
        }.padding(Spacing.large)
    }

    private func claude(_ provider: PlansPopupProvider) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack {
                Text(provider.title).font(.callout.weight(.semibold))
                if !provider.plan.isEmpty { Text(provider.plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let usage = provider.compactUsage { Text(usage).font(.caption).monospacedDigit() }
            }
            if let message = provider.message {
                Text(message).font(.caption).foregroundStyle(color(provider.messageTone)).fixedSize(horizontal: false, vertical: true)
                providerAction(provider)
            } else if let forecast = provider.primaryForecast {
                Text(forecast)
                    .font(.caption)
                    .foregroundStyle(color(provider.primaryTone))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(Spacing.medium).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func codex(_ provider: PlansPopupProvider) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Text(provider.title).font(.headline)
                if !provider.plan.isEmpty { Text(provider.plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if let message = provider.message {
                Text(message).font(.caption).foregroundStyle(color(provider.messageTone)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(provider.groups) { group in
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Text(group.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(group.quotas) { quota in quotaCard(quota) }
                }
            }
            if provider.message != nil { providerAction(provider) }
        }
    }

    private func quotaCard(_ quota: PlansPopupQuota) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                Text(quota.duration).font(.caption.weight(.semibold))
                if quota.isSelected && showInMenuBar {
                    Text(PlansPopupCopy.selected).font(.caption2).foregroundStyle(Tone.status("teal"))
                }
                Spacer(minLength: Spacing.small)
                Text(quota.reset).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Text(quota.percent).font(.caption.weight(.semibold)).monospacedDigit()
            }
            if let forecast = quota.forecast {
                Text(forecast).font(.caption).foregroundStyle(color(quota.tone)).fixedSize(horizontal: false, vertical: true)
            }
        }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    private func providerAction(_ provider: PlansPopupProvider) -> some View {
        Button(provider.action) { refresh(provider.id) }.buttonStyle(.kitQuiet).disabled(!provider.canRefresh)
    }

    private func color(_ tone: PlanUsageTone) -> Color {
        switch tone {
        case .critical: Tone.error
        case .warning: Tone.warning
        case .normal: Tone.success
        case .muted: Tone.status("gray")
        }
    }
}

/// Keeps the existing native application menu below the Plans panel.
struct TrayPopupContent<Actions: View>: View {
    let model: PlansPopupPresentation
    @Binding var showInMenuBar: Bool
    let openPlans: () -> Void
    let refresh: (PlanUsageProvider) -> Void
    let refreshAll: () -> Void
    let actions: () -> Actions

    init(
        model: PlansPopupPresentation,
        showInMenuBar: Binding<Bool>,
        openPlans: @escaping () -> Void,
        refresh: @escaping (PlanUsageProvider) -> Void,
        refreshAll: @escaping () -> Void,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.model = model
        _showInMenuBar = showInMenuBar
        self.openPlans = openPlans
        self.refresh = refresh
        self.refreshAll = refreshAll
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PlansMenuPanel(model: model, showInMenuBar: $showInMenuBar, openPlans: openPlans,
                               refresh: refresh, refreshAll: refreshAll)
                Menu(content: actions) {
                    MenuLabel(text: PlansPopupCopy.actions, systemImage: "ellipsis.circle", color: Tone.status("gray"))
                }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, Spacing.large)
                    .padding(.bottom, Spacing.medium)
            }
        }
            .frame(width: PlansLayout.menuWidth)
            .frame(maxHeight: PlansLayout.menuMaximumHeight)
            .fixedSize(horizontal: false, vertical: true)
            .popoverSurface()
    }
}
