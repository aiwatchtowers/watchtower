#if os(macOS)
import SwiftUI

/// TEMPORARY until the NSTextView composer moves here.
struct ChatComposerTextInput: View {
    @Binding var text: String
    @Binding var cursor: Int
    let placeholder: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
    }
}
#endif
