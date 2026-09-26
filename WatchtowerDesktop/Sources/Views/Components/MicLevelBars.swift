import SwiftUI

/// Compact mic level meter for the dictation capsule: `barCount` capsules lit
/// proportionally to `displayFraction(level)`.
struct MicLevelBars: View {
    let level: Float
    var barCount: Int = 5

    /// Pure normalization from raw chunk RMS to a 0…1 display fraction.
    /// Speech RMS sits roughly in 0.005–0.1, far below full scale — dividing
    /// by a 0.15 reference and square-rooting maps that band onto a visible
    /// range instead of leaving the bars dark during normal speech.
    static func displayFraction(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, (rms / 0.15).squareRoot())
    }

    var body: some View {
        let litBars = Int((Self.displayFraction(level) * Float(barCount)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(index < litBars ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 5 + CGFloat(index) * 2)
            }
        }
        .animation(.linear(duration: 0.1), value: litBars)
        .accessibilityHidden(true)
    }
}
