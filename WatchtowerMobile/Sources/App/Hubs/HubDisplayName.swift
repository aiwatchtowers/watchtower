import Foundation

/// The names the switcher and Settings show (multi-hub spec §5.6): the Mac's
/// name, with a short hub id suffix when two linked Macs share it.
enum HubDisplayName {
    static func names(for rows: [HubRow]) -> [String: String] {
        let counts = Dictionary(grouping: rows, by: \.link.macName).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let name = row.link.macName
            return (row.hubID, (counts[name] ?? 0) > 1 ? "\(name) · \(row.hubID.prefix(4))" : name)
        })
    }
}
