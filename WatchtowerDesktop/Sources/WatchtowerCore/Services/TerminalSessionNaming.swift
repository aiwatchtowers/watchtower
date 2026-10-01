import Foundation

/// Provisional titles for embedded-terminal sessions, before an AI or the
/// owner names them.
package enum TerminalSessionNaming {
    package static let setupTitle = "Project setup"

    package static func provisional(now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return String(format: "New session · %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "<shell basename> — <folder basename>", e.g. "zsh — acme".
    package static func shell(shellPath: String?, folder: String) -> String {
        let shellName = shellPath.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "zsh"
        return "\(shellName) — \((folder as NSString).lastPathComponent)"
    }
}
