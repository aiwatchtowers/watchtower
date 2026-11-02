import SwiftUI

/// The actual NSMenu plan items, also hosted by the production design shots.
struct PlansTrayRows: View {
    let lines: [String]
    let action: () -> Void

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Button(line, action: action)
        }
    }
}
