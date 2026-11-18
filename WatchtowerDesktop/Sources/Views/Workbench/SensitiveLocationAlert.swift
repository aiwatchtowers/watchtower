import SwiftUI

/// Open Folder…'s warning for a folder under a TCC-sensitive location
/// (`WorkbenchFolderPolicy.tccSensitiveLocation`): the embedded terminal
/// runs as part of Watchtower, so macOS may ask about it. Shared by Open
/// Folder…, a terminal in a folder, Put on the Bench… and the agent's
/// folder suggestion (#2003, spec §6.1/§6.7: "applies unchanged").
extension View {
    func sensitiveLocationAlert(
        _ location: Binding<String?>,
        cancelLabel: String = "Choose another folder",
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        alert(
            "Folder in \(location.wrappedValue ?? "")",
            isPresented: Binding(get: { location.wrappedValue != nil }, set: { if !$0 { location.wrappedValue = nil } })
        ) {
            Button("Open anyway", action: onConfirm)
            Button(cancelLabel, role: .cancel, action: onCancel)
        } message: {
            Text(
                "The embedded terminal runs as part of Watchtower, so macOS may ask whether "
                    + "Watchtower can access \(location.wrappedValue ?? "this folder"). A folder outside Documents, "
                    + "Desktop, Downloads and cloud storage avoids that prompt."
            )
        }
    }
}
