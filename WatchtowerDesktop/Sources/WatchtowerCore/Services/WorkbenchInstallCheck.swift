import Foundation

/// The Desktop's half of the launch backstop after a bench merge (#2003, spec
/// §6.13, D37): before the Desktop launches an agent itself (resume, Start
/// fresh), it reads which workbench the folder's hooks name. Only a folder
/// installed for another workbench, never for the row's own, asks Go to
/// reinstall (`workbench session ensure-install`); a folder with no install
/// launches as it always did. Go's twin is `devpack.InstalledWorkbenchIDs`.
package enum WorkbenchInstallCheck {
    /// The state hook's command tail: ` workbench session-state --workbench <id>`.
    private static let marker = " workbench session-state --workbench "

    /// Every workbench id whose UserPromptSubmit state hook is in the
    /// settings file's JSON, in file order; empty for anything unreadable.
    package static func installedIDs(settings data: Data) -> [Int64] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["UserPromptSubmit"] as? [Any] else { return [] }
        var ids: [Int64] = []
        for case let group as [String: Any] in groups {
            for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                guard let command = hook["command"] as? String,
                      let range = command.range(of: marker, options: .backwards),
                      let id = Int64(command[range.upperBound...].trimmingCharacters(in: .whitespaces)),
                      !ids.contains(id) else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    /// The settings file the hooks live in.
    package static func settingsPath(folder: String) -> String {
        (folder as NSString).appendingPathComponent(".claude/settings.local.json")
    }

    /// Whether `folder` is installed for another workbench and not for
    /// `workbenchID`: the merge left it behind, Go reinstalls it.
    package static func needsReinstall(folder: String, workbenchID: Int64) -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath(folder: folder)) else { return false }
        let ids = installedIDs(settings: data)
        return !ids.isEmpty && !ids.contains(workbenchID)
    }
}
