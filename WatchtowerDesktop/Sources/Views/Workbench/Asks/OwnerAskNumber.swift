import SwiftUI

extension Text {
    /// An ask's compact number, "#145" (board #500): small, monospaced and
    /// secondary, so it leads a line of the ask without taking its room.
    static func askNumber(_ id: Int64) -> Text {
        Text(verbatim: "#\(id)").font(.caption2.monospaced()).foregroundStyle(.secondary)
    }
}
