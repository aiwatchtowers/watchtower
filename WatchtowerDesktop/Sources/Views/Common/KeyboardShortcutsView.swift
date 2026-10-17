import SwiftUI
import WatchtowerCore

/// Help › Keyboard Shortcuts (issue #288): `KeyboardShortcutCatalog`, one
/// section per area.
struct KeyboardShortcutsView: View {
    static let sceneID = "keyboard-shortcuts"

    var body: some View {
        List {
            ForEach(KeyboardShortcutCatalog.areas) { area in
                Section(area.title) {
                    if let note = area.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(area.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.keys)
                                .font(.body.monospaced())
                                .frame(width: 150, alignment: .leading)
                            Text(entry.action)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(minWidth: 480, minHeight: 400)
    }
}
