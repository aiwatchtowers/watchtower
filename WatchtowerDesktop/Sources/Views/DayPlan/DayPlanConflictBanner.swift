import SwiftUI

struct DayPlanConflictBanner: View {
    let summary: String?
    let onRegenerate: () -> Void
    let onCheckAgain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar conflicts detected")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button("Regenerate", action: onRegenerate)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                Button("Check again", action: onCheckAgain)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.red.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}
