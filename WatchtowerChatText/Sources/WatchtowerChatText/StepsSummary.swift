import Foundation

/// The steps block header (spec §3.2.1): "Worked for 12s · 4 steps".
public enum StepsSummary {
    public static func header(stepCount: Int, elapsed: TimeInterval, running: Bool) -> String {
        let steps = stepCount == 1 ? "1 step" : "\(stepCount) steps"
        return running ? "Working… · \(steps)" : "Worked for \(duration(elapsed)) · \(steps)"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }
}
