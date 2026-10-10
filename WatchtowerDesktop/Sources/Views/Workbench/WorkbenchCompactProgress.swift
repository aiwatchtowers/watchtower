import SwiftUI

/// The board's one compact progress row — a small linear bar, green when
/// complete, and a caption: the lane header, the path bar, the group panel's
/// "N of M done" and a task's percentage.
struct WorkbenchCompactProgress: View {
    /// 0...1.
    let fraction: Double
    let label: String
    /// Nil lets the bar take the width it is offered.
    var barWidth: CGFloat?

    init(fraction: Double, label: String, barWidth: CGFloat? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.label = label
        self.barWidth = barWidth
    }

    /// `done` of `total`; an empty `total` reads as nothing done.
    init(done: Int, total: Int, label: String, barWidth: CGFloat? = nil) {
        self.init(fraction: total > 0 ? Double(done) / Double(total) : 0, label: label, barWidth: barWidth)
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(fraction >= 1 ? .green : .accentColor)
                .frame(width: barWidth)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
