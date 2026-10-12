import SwiftUI

/// "The Mac doesn't show up" (spec §2.3 failure table): what the Mac needs
/// before it can show a code.
struct MacNotShowingView: View {
    static let checklist = [
        "Watchtower is open on the Mac",
        "Settings → Mobile is on",
        "The Mac is awake",
        "It is a signed build",
        "iCloud is on"
    ]

    var body: some View {
        List {
            Section {
                ForEach(Array(Self.checklist.enumerated()), id: \.offset) { index, item in
                    Label {
                        Text(item)
                    } icon: {
                        Image(systemName: "\(index + 1).circle").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
            } header: {
                Text("Check on your Mac")
            } footer: {
                Text("Then choose Use Watchtower on iPhone in Settings → Mobile on the Mac, and scan the code it shows.")
            }
        }
        .navigationTitle("The Mac doesn't show up")
        .navigationBarTitleDisplayMode(.inline)
    }
}
