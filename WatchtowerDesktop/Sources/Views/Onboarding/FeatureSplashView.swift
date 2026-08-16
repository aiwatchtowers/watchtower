import SwiftUI
import WatchtowerCore

/// The final onboarding step (owner decision: new users only — existing
/// installs already have Settings → Features, no what's-new mechanism) — a
/// selling screen built directly on `FeatureManagerService`
/// (`appState.featureManager`, the same service Settings → Features uses).
/// Reuses its `pending`/`setPending`/`apply` contract as-is: toggling a card
/// stages a change, Continue replays the staged batch through the CLI and
/// restarts the daemon once (only if something actually changed), "Keep
/// everything on" discards whatever was staged.
///
/// Deliberately simpler than `FeatureManagerSection`: no cascade-confirmation
/// dialog — unchecking a card here never implicitly disables anything else
/// (FEAT-04, "no silent cascade"; a dependent left on just runs degraded,
/// which is fine for a first-run pick) — and no sub-toggle editing (Memory's
/// "Advanced" disclosure stays a Settings-only affordance).
struct FeatureSplashView: View {
    /// Returns whether onboarding actually finished (`OnboardingCompletion.finish`'s
    /// result) — `false` means the DB write failed and nothing else ran, so
    /// the splash stays up and shows an inline retry instead of moving on.
    let onFinish: () async -> Bool

    @Environment(AppState.self) private var appState
    /// Set when the most recent `onFinish()` call returned `false`. Distinct
    /// from `service.loadError`: that one is about the feature list/apply
    /// step, this one is about the completion step that runs after it.
    @State private var finishFailed = false

    private var service: FeatureManagerService { appState.featureManager }

    private var coreFeatures: [FeatureInfo] {
        service.features.filter(\.core)
    }

    /// Cards shown in the grid: every top-level toggleable feature (not
    /// core, not itself somebody else's child row — e.g. Stream Digests is
    /// rendered folded into its parent Slack Digests card instead).
    private var toggleableFeatures: [FeatureInfo] {
        service.features.filter { $0.parent.isEmpty && !$0.core }
    }

    private func children(of parentID: String) -> [FeatureInfo] {
        service.features.filter { $0.parent == parentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    contentBody
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await service.load() }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text("Watchtower works for you around the clock.")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text("Pick what it should do. Everything runs on your Mac; "
                + "change any of this later in Settings → Features.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
    }

    /// Loading spinner while the very first `load()` is in flight, nothing
    /// while it failed with an empty list (the footer's error banner already
    /// explains and offers Retry — an empty "Always included" row plus an
    /// empty grid underneath it would just read as broken), or the real
    /// content once features are in hand.
    @ViewBuilder
    private var contentBody: some View {
        if service.features.isEmpty {
            if service.loadError == nil {
                ProgressView("Loading features…")
                    .padding(.top, 40)
            }
        } else {
            alwaysIncludedSection
            featureGrid
        }
    }

    // MARK: - Always included

    private var alwaysIncludedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Always included")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(coreFeatures) { feature in
                    corePill(feature)
                }
            }
        }
    }

    private func corePill(_ feature: FeatureInfo) -> some View {
        VStack(spacing: 6) {
            Image(systemName: feature.icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text(feature.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
            Text(feature.tagline)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Feature grid

    private var featureGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)],
            spacing: 16
        ) {
            ForEach(toggleableFeatures) { feature in
                featureCard(feature)
            }
        }
    }

    private func featureCard(_ feature: FeatureInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: feature.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(feature.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if isExperimental(feature) {
                            experimentalTag
                        }
                    }
                    Text(feature.tagline)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: featureBinding(feature))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(feature.benefits, id: \.self) { benefit in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•").foregroundStyle(.secondary)
                        Text(benefit)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let costLabel = costWords(feature.cost) {
                Text(costLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(children(of: feature.id)) { child in
                childRow(child)
            }

            if let powered = poweredCaption(feature) {
                Text(powered)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// A child feature (e.g. Stream Digests under Slack Digests) folded into
    /// its parent's card as a secondary line — title and its own toggle
    /// only, no benefits/cost/Powers of its own.
    private func childRow(_ child: FeatureInfo) -> some View {
        HStack(spacing: 8) {
            Text(child.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: featureBinding(child))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.top, 2)
    }

    private var experimentalTag: some View {
        Text("Experimental")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = service.loadError {
                errorBanner(error)
            }
            if finishFailed {
                finishErrorBanner
            }
            HStack(spacing: 16) {
                Button("Keep everything on") {
                    keepEverythingOnTapped()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()

                Button {
                    continueTapped()
                } label: {
                    HStack {
                        if service.isApplying {
                            ProgressView().controlSize(.small)
                        }
                        Text("Continue")
                    }
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .disabled(service.isApplying)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
            Spacer()
            // Retry re-runs load() only when there is nothing to show yet.
            // Once features ARE loaded, a lingering loadError is an apply()
            // failure instead, and a second Continue is what retries the
            // still-pending remainder (below) — a Retry button here would
            // just re-fetch the same list without touching pending at all.
            if service.features.isEmpty {
                Button("Retry") {
                    Task { await service.load() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// Shown when `onFinish()` itself returned `false` (the DB "onboarding
    /// done" write failed) — distinct from `errorBanner`, which is about the
    /// feature list/apply step. No per-failure detail is available across
    /// the `onFinish` boundary (a plain success/fail signal, wired in
    /// `OnboardingView.finishOnboarding()`), so this is a fixed message.
    private var finishErrorBanner: some View {
        HStack(spacing: 12) {
            Text("Couldn't finish setup. Please try again.")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
            Spacer()
            Button("Retry") {
                retryFinishTapped()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func continueTapped() {
        Task {
            // Captured before the call, mirroring FeaturesSettings: apply()
            // is a no-op guarded by !pending.isEmpty that returns without
            // touching loadError at all when nothing was staged, so checking
            // loadError unconditionally afterward would treat a stale
            // load() failure as an apply failure and trap the user even
            // though nothing they staged actually failed to apply.
            let hadPendingChanges = !service.pending.isEmpty
            await service.apply { await DaemonManager.restart() }
            guard !(hadPendingChanges && service.loadError != nil) else { return }
            await runFinish()
        }
    }

    private func keepEverythingOnTapped() {
        // Discard whatever was staged — the CLI defaults already on disk
        // stay in effect, nothing to apply. Must work even when load()
        // failed: completion must never depend on a working feature list (a
        // broken CLI must not trap a new user in onboarding).
        service.pending.removeAll()
        Task { await runFinish() }
    }

    /// By the time either exit reaches this point, `pending` is already
    /// empty either way (apply() cleared what succeeded, "Keep everything
    /// on" discarded the rest) — so a failed finish's retry is always just a
    /// bare re-run of `onFinish()`, regardless of which button got here.
    private func retryFinishTapped() {
        Task { await runFinish() }
    }

    private func runFinish() async {
        finishFailed = !(await onFinish())
    }

    // MARK: - Bindings & derived text

    /// No cascade dialog, unlike `FeatureManagerSection`: the splash only
    /// ever stages the one feature the owner touched (FEAT-04 — a dependent
    /// left enabled just runs degraded, which is fine for a first-run pick).
    private func featureBinding(_ feature: FeatureInfo) -> Binding<Bool> {
        Binding(
            get: { !service.disabledFeatureIDs.contains(feature.id) },
            set: { service.setPending(feature.id, enabled: $0) }
        )
    }

    /// Keyed off the freshly-loaded `state`, not `disabledFeatureIDs` (which
    /// folds in the owner's own not-yet-applied toggle for THIS card): the
    /// tag means "this ships off by default", not "is currently off in this
    /// session" — toggling some other card off must never make an unrelated
    /// card suddenly read as experimental.
    private func isExperimental(_ feature: FeatureInfo) -> Bool {
        feature.state == "disabled"
    }

    private func costWords(_ cost: String) -> String? {
        switch cost {
        case "heavy": return "Uses AI heavily"
        case "medium": return "Uses AI moderately"
        case "light": return "Uses AI lightly"
        default: return nil // "none"
        }
    }

    private func poweredCaption(_ feature: FeatureInfo) -> String? {
        guard !feature.feedsInto.isEmpty else { return nil }
        let titles = feature.feedsInto.compactMap { id in
            service.features.first { $0.id == id }?.title
        }
        guard !titles.isEmpty else { return nil }
        return "Powers: " + titles.joined(separator: ", ")
    }
}
