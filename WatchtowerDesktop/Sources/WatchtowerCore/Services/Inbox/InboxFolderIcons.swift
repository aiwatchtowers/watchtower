import Foundation

/// The SF Symbols an owner folder may take (spec "Folders"): the same list,
/// in the same order, as Go's `internal/inboxfolders/icons.json`, which the
/// CLI validates against (`InboxFolderIconsTests` pins the two).
package enum InboxFolderIcons {
    package static let all: [String] = [
        "folder", "tray", "tray.full", "flag", "bolt", "star", "bookmark", "tag",
        "person", "person.2", "doc.text", "calendar", "clock", "shippingbox", "lightbulb", "bell",
        "envelope", "bubble.left", "briefcase", "hammer", "chart.bar", "checkmark.circle",
        "exclamationmark.triangle", "sparkles"
    ]

    /// What an empty icon draws.
    package static let defaultIcon = "folder"

    /// The symbol a stored icon draws: empty, or a name the list no longer
    /// holds, draws `folder`.
    package static func symbol(for icon: String) -> String {
        all.contains(icon) ? icon : defaultIcon
    }
}
