import SwiftUI
import WatchtowerCore

/// A collapsed disclosure that shows a recipe read-only in the Monaco editor
/// (`RecipeEditorView`): the confirmation sheet's "Show the script" and the
/// `save_automation` card's whole new recipe. It owns its buffer; a new
/// `contentHash` resets it to `text`.
struct RecipeTextDisclosure: View {
    let title: String
    let text: String
    /// Names the page's model (`automation-<id>`); any id unique on screen.
    let modelID: Int64
    let contentHash: String
    let slug: String
    var height: CGFloat = 260

    @State private var buffer: RecipeBufferModel?
    @State private var shown = false

    var body: some View {
        DisclosureGroup(title, isExpanded: $shown) {
            if let buffer {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = buffer.pageError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    RecipeEditorView(buffer: buffer, readOnly: true, slug: slug)
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .task(id: contentHash) { sync() }
    }

    private func sync() {
        if let buffer {
            if buffer.baseContentHash != contentHash {
                buffer.reset(text: text, contentHash: contentHash)
            }
        } else {
            buffer = RecipeBufferModel(automationID: modelID, text: text, contentHash: contentHash)
        }
    }
}
