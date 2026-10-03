import SwiftUI
import WatchtowerCore

/// One margin comment of a review: a draft's (editable while the ask is)
/// or a closed ask's stored one.
struct OwnerAskMarginComment: Identifiable, Equatable {
    let id: String
    /// The draft comment it edits; nil shows it read-only.
    let draftID: UUID?
    let anchor: CommentAnchor
    let body: String
    /// Its passage was found in the snapshot.
    let placed: Bool
}

/// The review body's margin (spec 2026-10-03 Part 8): each comment beside
/// its passage's line, collisions pushed down (`OwnerAskMarginLayout`),
/// following the text as it scrolls.
struct OwnerAskMarginComments: View {
    let comments: [OwnerAskMarginComment]
    /// Each comment's passage box in the text's visible area, in order;
    /// shorter (or nil entries) until the text view has reported them.
    let rects: [CGRect?]
    @Binding var active: String?
    let setBody: (UUID, String) -> Void
    let remove: (UUID) -> Void
    @State private var heights: [String: CGFloat] = [:]

    private static let estimatedHeight: CGFloat = 64

    var body: some View {
        let tops = OwnerAskMarginLayout.tops(comments.indices.map { index in
            .init(anchorY: index < rects.count ? rects[index]?.minY : nil,
                  height: heights[comments[index].id] ?? Self.estimatedHeight)
        })
        ZStack(alignment: .topLeading) {
            ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                card(comment)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { heights[comment.id] = $0 })
                    .offset(y: tops[index])
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Color.secondary.opacity(0.04))
        .overlay(alignment: .leading) { Divider() }
    }

    private func card(_ comment: OwnerAskMarginComment) -> some View {
        let isActive = comment.id == active
        return VStack(alignment: .leading, spacing: 4) {
            Text(comment.anchor.quote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let draftID = comment.draftID {
                TextField("Comment", text: Binding(get: { comment.body }, set: { setBody(draftID, $0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                HStack {
                    Spacer()
                    Button("Remove") { remove(draftID) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                Text(comment.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !comment.placed {
                Text("Passage not found").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isActive ? 1.5 : 1)
        )
        .simultaneousGesture(TapGesture().onEnded { active = comment.id })
    }
}
