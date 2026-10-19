import SwiftUI

/// A section title inside the target panel (Description, Sub-tasks, Asks,
/// Images, Comments), so every section reads the same.
public struct SectionHeader: View {
    let title: String
    let systemImage: String
    var count: Int?

    public init(title: String, systemImage: String, count: Int? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}
