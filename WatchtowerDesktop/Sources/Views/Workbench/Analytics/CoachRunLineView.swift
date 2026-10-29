import SwiftUI
import WatchtowerCore

/// "The coach looks once a week · last run … · next after …" and Run Now.
struct CoachRunLineView: View {
    let coach: CoachCenter
    let lastRun: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                if coach.running {
                    ProgressView().controlSize(.small)
                    Text("The coach is looking at the last 28 days…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(Self.line(lastRun: lastRun)).font(.caption).foregroundStyle(.secondary)
                }
                Button("Run Now") { Task { await coach.runNow() } }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
                    .disabled(coach.running)
            }
            if let line = coach.runLine {
                Label(line, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
            }
        }
    }

    static func line(lastRun: String?, timeZone: TimeZone = .current) -> String {
        let base = "The coach looks once a week"
        guard let lastRun, let date = AgentAnalyticsFormat.reportDate(lastRun) else { return base + " · no run yet" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d"
        let next = date.addingTimeInterval(7 * 24 * 3600)
        return "\(base) · last run \(formatter.string(from: date)) · next after \(formatter.string(from: next))"
    }
}
