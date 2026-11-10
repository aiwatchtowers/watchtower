import SwiftUI

/// Buying and restoring the Relay subscription (mockup S20–S29, S42–S46, S57). It only reads `RelaySubscriptionModel` and
/// calls the center; StoreKit stays behind the center. It opens only from what a relay-available build shows.
struct RelaySubscriptionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// A model to show in place of the live one (the screenshot tour's frames); its actions do nothing.
    private let modelOverride: RelaySubscriptionModel?

    init(model: RelaySubscriptionModel? = nil) {
        modelOverride = model
    }

    private var center: RelayAccountCenter? { modelOverride == nil ? env.relayAccount : nil }

    private var model: RelaySubscriptionModel? {
        if let modelOverride { return modelOverride }
        guard let center else { return nil }
        return RelaySubscriptionModel(
            purchase: center.purchase, unconfirmed: center.unconfirmed, phase: center.phase,
            config: .from(bundle: .main), product: center.product, updateRequired: center.updateRequired
        )
    }

    var body: some View {
        ScrollView {
            if let model {
                content(model)
                    .padding(.horizontal, Spacing.large)
                    .padding(.bottom, Spacing.wide)
            }
        }
        .navigationTitle(RelaySubscriptionModel.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await center?.loadProduct() }
        // Not `.task(id:)`: the load's own write would change the id, SwiftUI would cancel the task, and a cancelled
        // `Product.products` can land on a false S22.
        .onChange(of: center?.purchase) { _, purchase in
            guard let purchase, RelaySubscriptionModel.loadsProduct(on: purchase) else { return }
            Task { await center?.loadProduct() }
        }
        .onDisappear { center?.screenClosed() }
    }

    private func content(_ model: RelaySubscriptionModel) -> some View {
        VStack(spacing: Spacing.large) {
            if let lead = model.lead {
                pitch(lead: lead, bullets: model.bullets)
                primary(model)
                if let line = model.line {
                    lineText(line, isError: model.lineIsError).font(TypeScale.meta)
                }
            } else {
                if let line = model.line {
                    lineText(line, isError: model.lineIsError)
                        .font(.body.weight(.semibold))
                        .padding(.top, Spacing.wide)
                }
                primary(model)
            }
            footer(model)
        }
        .padding(.top, Spacing.regular)
    }

    private func pitch(lead: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(lead)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(bullet).fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(.plain)
    }

    private func lineText(_ line: String, isError: Bool) -> some View {
        Text(line)
            .foregroundStyle(isError ? PhoneTone.red.color : Color.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func primary(_ model: RelaySubscriptionModel) -> some View {
        if let button = model.primary {
            Button(button.title) {
                if let action = button.action { press(action, model: model) }
            }
            .buttonStyle(ProminentActionStyle())
            .disabled(button.action == nil)
        }
    }

    private func press(_ action: RelaySubscriptionModel.Button.Action, model: RelaySubscriptionModel) {
        guard modelOverride == nil else { return }
        switch action {
        case .subscribe: Task { await center?.buy() }
        case .reloadProduct: Task { await center?.reloadProduct() }
        case .retryAccount: Task { await center?.retryAccount() }
        case .retryConfirm: Task { await center?.retryConfirm() }
        case .manageSubscription: if let url = model.manageSubscriptionURL { openURL(url) }
        case .done: dismiss()
        }
    }

    /// One row while it fits, stacked at the largest text sizes.
    private func footer(_ model: RelaySubscriptionModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.medium) { footerLinks(model) }
            VStack(spacing: 0) { footerLinks(model) }
        }
        .font(TypeScale.meta)
    }

    @ViewBuilder private func footerLinks(_ model: RelaySubscriptionModel) -> some View {
        Button(RelaySubscriptionModel.restoreTitle) {
            guard modelOverride == nil else { return }
            Task { await center?.restore() }
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.restoreTone.color)
        .frame(minHeight: PhoneMetrics.minTouch)
        .disabled(!model.showsRestore)
        footerLink(RelaySubscriptionModel.termsTitle, model.termsURL)
        footerLink(RelaySubscriptionModel.privacyTitle, model.privacyURL)
    }

    @ViewBuilder private func footerLink(_ title: String, _ url: URL?) -> some View {
        if let url {
            Link(title, destination: url)
                .foregroundStyle(PhoneTone.accent.color)
                .frame(minHeight: PhoneMetrics.minTouch)
        }
    }
}
