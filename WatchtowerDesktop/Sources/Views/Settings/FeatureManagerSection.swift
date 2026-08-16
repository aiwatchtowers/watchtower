import SwiftUI
import WatchtowerCore

/// Settings → Features top section: the on/off manager for every registry
/// pillar (`internal/features/registry.go`), rendered from
/// `FeatureManagerService`. A toggle here only stages a change into
/// `service.pending` / `service.applyWithDependents` — the actual CLI calls
/// and the one daemon restart happen later, when the surrounding
/// `ConfigSaveBar`'s Save button runs `FeatureManagerService.apply(restart:)`
/// via its `extraSave` hook (`FeaturesSettings`).
struct FeatureManagerSection: View {
    let service: FeatureManagerService
    @State private var cascadeCandidate: CascadeCandidate?

    private var topLevelFeatures: [FeatureInfo] {
        service.features.filter { $0.parent.isEmpty }
    }

    var body: some View {
        Section("Features") {
            if service.features.isEmpty && service.loadError == nil {
                ProgressView("Loading features…")
            } else {
                ForEach(topLevelFeatures) { feature in
                    featureBlock(feature)
                }
            }
            if let error = service.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(service.isApplying)
        .onAppear {
            Task { await service.load() }
        }
        .confirmationDialog(
            "Disable \(cascadeCandidate?.feature.title ?? "")?",
            isPresented: Binding(
                get: { cascadeCandidate != nil },
                set: { if !$0 { cascadeCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: cascadeCandidate
        ) { candidate in
            Button("Disable only \(candidate.feature.title)") {
                service.setPending(candidate.feature.id, enabled: false)
                cascadeCandidate = nil
            }
            Button(cascadeAndDependentsLabel(candidate)) {
                service.applyWithDependents.insert(candidate.feature.id)
                service.setPending(candidate.feature.id, enabled: false)
                cascadeCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                cascadeCandidate = nil
            }
        } message: { candidate in
            Text("This also affects: " + candidate.dependents.map(\.title).joined(separator: ", "))
        }
    }

    private func cascadeAndDependentsLabel(_ candidate: CascadeCandidate) -> String {
        let count = candidate.dependents.count
        return "Disable \(candidate.feature.title) and \(count) dependent\(count == 1 ? "" : "s")"
    }

    // MARK: - Rows

    @ViewBuilder
    private func featureBlock(_ feature: FeatureInfo) -> some View {
        featureRow(feature, indent: 0)
        ForEach(children(of: feature.id)) { child in
            featureRow(child, indent: 20)
        }
        if !feature.subToggles.isEmpty {
            DisclosureGroup("Advanced") {
                ForEach(feature.subToggles, id: \.key) { sub in
                    subToggleRow(sub)
                }
            }
            .padding(.leading, 20)
        }
    }

    private func children(of parentID: String) -> [FeatureInfo] {
        service.features.filter { $0.parent == parentID }
    }

    private func featureRow(_ feature: FeatureInfo, indent: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                Text(feature.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            costBadge(feature.cost)
            if feature.core {
                Text("Core")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            } else {
                Toggle("", isOn: featureBinding(feature))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .padding(.leading, indent)
    }

    private func subToggleRow(_ sub: FeatureSubToggle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.title)
                    .font(.subheadline)
                Text(sub.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: subToggleBinding(sub))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func costBadge(_ cost: String) -> some View {
        Text(cost.capitalized)
            .font(.caption2)
            .foregroundStyle(costColor(cost))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(costColor(cost).opacity(0.12), in: Capsule())
    }

    private func costColor(_ cost: String) -> Color {
        switch cost {
        case "heavy": return .red
        case "medium": return .orange
        case "light": return .blue
        default: return .secondary
        }
    }

    // MARK: - Bindings

    /// The toggle's displayed state never optimistically flips on the OFF
    /// direction: `handleToggle` only stages a disable (directly, or via the
    /// cascade dialog) after `dependents(of:)` resolves, so a row with
    /// dependents stays visually ON until the owner actually confirms.
    private func featureBinding(_ feature: FeatureInfo) -> Binding<Bool> {
        Binding(
            get: { !service.disabledFeatureIDs.contains(feature.id) },
            set: { enabled in handleToggle(feature, enabled: enabled) }
        )
    }

    private func handleToggle(_ feature: FeatureInfo, enabled: Bool) {
        guard !enabled else {
            service.setPending(feature.id, enabled: true)
            return
        }
        Task {
            let dependents = await service.dependents(of: feature.id)
            if dependents.isEmpty {
                service.setPending(feature.id, enabled: false)
            } else {
                cascadeCandidate = CascadeCandidate(feature: feature, dependents: dependents)
            }
        }
    }

    private func subToggleBinding(_ sub: FeatureSubToggle) -> Binding<Bool> {
        Binding(
            get: { service.pending[sub.key] ?? sub.enabled },
            set: { service.setPending(sub.key, enabled: $0) }
        )
    }
}

// MARK: - CascadeCandidate

/// A feature the owner just toggled off that has currently-enabled
/// dependents — the input for the cascade-confirmation dialog (FEAT-04).
private struct CascadeCandidate: Identifiable {
    let feature: FeatureInfo
    let dependents: [FeatureDependents.Dependent]
    var id: String { feature.id }
}
