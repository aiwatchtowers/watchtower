#if os(macOS)
import SwiftUI

/// TEMPORARY until the Mac's sandboxed HTML view glue moves here.
struct ChatArtifactHTMLView: View {
    let html: String

    var body: some View {
        Text(html).font(.caption.monospaced())
    }
}
#endif
