import SwiftUI
import WatchtowerCore

/// Onboarding's "Customize features" screen, opened from the Goals step:
/// the switches edit an `OnboardingFeatureSelection` owned by the caller
/// (preset from the goals) and nothing is written here — the Goals step
/// applies the selection with `FeatureManagerService.applySelection`, which
/// never restarts the daemon. Built on `FeatureManagerService`
/// (`appState.featureManager`) for the list itself.
struct FeatureCustomizeView: View {
    @Binding var selection: OnboardingFeatureSelection
    /// Back to the Goals step; the selection is already up to date by then.
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    /// Which rows carry the "Experimental" tag, snapshotted at the first
    /// successful load (nil until then). See `isExperimental`.
    @State private var experimentalIDs: Set<String>?

    private var service: FeatureManagerService { appState.featureManager }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                customizeBody($selection)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            Divider()
            customizeFooter($selection, onDone: onDone)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(service.isApplying)
        .onAppear {
            Task {
                await service.load()
                captureExperimentalIDs()
            }
        }
    }

    /// Registry order, as the CLI lists it.
    private var customizableFeatures: [FeatureInfo] {
        service.features.filter { OnboardingFeaturePlan.customizableFeatureIDs.contains($0.id) }
    }

    /// Core entries, the features onboarding always switches on (unless
    /// this selection keeps one off — a re-run of a setup that turned it
    /// off in Settings), and Workbench (no feature switch at all).
    private func alwaysOnTitles(_ selection: OnboardingFeatureSelection) -> [String] {
        service.features
            .filter { $0.core || (OnboardingFeaturePlan.alwaysOnFeatureIDs.contains($0.id) && selection.isEnabled($0.id)) }
            .map(\.title) + ["Workbench"]
    }

    /// The always-on features this selection keeps off.
    private func keptOffTitles(_ selection: OnboardingFeatureSelection) -> [String] {
        service.features
            .filter { OnboardingFeaturePlan.alwaysOnFeatureIDs.contains($0.id) && !selection.isEnabled($0.id) }
            .map(\.title)
    }

    @ViewBuilder
    private func customizeBody(_ selection: Binding<OnboardingFeatureSelection>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Features")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Preset from your goals. A feature that's off doesn't run in the background and hides its tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if service.features.isEmpty {
                if service.loadError == nil {
                    ProgressView("Loading features…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            } else {
                (Text("Always on: ").foregroundStyle(.secondary)
                    + Text(alwaysOnTitles(selection.wrappedValue).joined(separator: " · ")))
                    .font(.caption)
                let keptOff = keptOffTitles(selection.wrappedValue)
                if !keptOff.isEmpty {
                    (Text("Off (as in Settings): ").foregroundStyle(.secondary)
                        + Text(keptOff.joined(separator: " · ")))
                        .font(.caption)
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 8
                ) {
                    ForEach(customizableFeatures) { feature in
                        customizeRow(feature, selection: selection)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func customizeRow(_ feature: FeatureInfo, selection: Binding<OnboardingFeatureSelection>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if let cost = compactCostWords(feature.cost) {
                        Text("· " + cost)
                            .font(.caption)
                            .foregroundStyle(feature.cost == "heavy" ? .orange : .secondary)
                    }
                    if isExperimental(feature) {
                        experimentalTag
                    }
                }
                Text(feature.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { selection.wrappedValue.isEnabled(feature.id) },
                set: { selection.wrappedValue.setFeature(feature.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func customizeFooter(_ selection: Binding<OnboardingFeatureSelection>, onDone: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            if let error = service.loadError {
                errorBanner(error)
            }
            HStack(spacing: 16) {
                Button("Reset to goals") {
                    selection.wrappedValue.resetToGoals()
                }
                .buttonStyle(.borderless)
                .disabled(!selection.wrappedValue.isCustomized)

                Spacer()

                Button {
                    onDone()
                } label: {
                    Text("Done").fontWeight(.semibold).frame(minWidth: 120)
                }
                .onboardingPrimaryButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func compactCostWords(_ cost: String) -> String? {
        switch cost {
        case "heavy": return "heavy AI"
        case "medium": return "medium"
        case "light": return "light"
        default: return nil // "none"
        }
    }

    /// Fills the snapshot from the first load that actually returned
    /// features; later loads leave it alone. An unsuccessful load leaves it
    /// nil, so the next successful one still gets to fill it. Memory is
    /// never tagged (`OnboardingFeaturePlan.experimentalFeatureIDs`).
    private func captureExperimentalIDs() {
        guard experimentalIDs == nil, !service.features.isEmpty else { return }
        experimentalIDs = OnboardingFeaturePlan.experimentalFeatureIDs(service.features.map { ($0.id, $0.state) })
    }

    /// Read from a snapshot taken at the first successful load, not from the
    /// live `state`: the tag means "off at the screen's first load", not "is
    /// currently off" — a later reload (Goals' Continue applying the
    /// selection) reports what the owner switched off as `disabled` too.
    private func isExperimental(_ feature: FeatureInfo) -> Bool {
        experimentalIDs?.contains(feature.id) ?? false
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
            Spacer()
            // Retry re-reads the list, offered only while there is nothing to
            // show: this screen writes nothing, so with a list on screen the
            // error is a stale one and Goals' Continue reports its own.
            if service.features.isEmpty {
                Button("Retry") {
                    Task {
                        await service.load()
                        captureExperimentalIDs()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
