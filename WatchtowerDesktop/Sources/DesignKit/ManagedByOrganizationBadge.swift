import SwiftUI

/// The mark of a control the organization's policy decides (#608): a lock
/// and "Managed by your organization", small and secondary.
public struct ManagedByOrganizationBadge: View {
    public static let text = "Managed by your organization"

    public init() {}

    public var body: some View {
        Label(Self.text, systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

public extension View {
    /// Locks a control the organization's policy decides: disabled, with the
    /// badge under it and the same words as its help. Unlocked, the control
    /// is unchanged. Every policy lock in the app uses this.
    func managedByOrganization(_ locked: Bool) -> some View {
        modifier(ManagedByOrganizationModifier(locked: locked))
    }
}

struct ManagedByOrganizationModifier: ViewModifier {
    let locked: Bool

    func body(content: Content) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.tight) {
            content.disabled(locked)
            if locked {
                ManagedByOrganizationBadge()
            }
        }
        .help(locked ? ManagedByOrganizationBadge.text : "")
    }
}
