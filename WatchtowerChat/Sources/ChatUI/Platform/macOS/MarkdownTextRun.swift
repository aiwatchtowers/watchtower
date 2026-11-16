#if os(macOS)
import SwiftUI

/// TEMPORARY until the TextKit 2 answer text moves here.
struct ChatAnswerText: View {
    let text: String
    let isFinal: Bool
    let isOwner: Bool

    var body: some View {
        Text(text).textSelection(.enabled)
    }
}
#endif
