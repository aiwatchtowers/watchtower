@testable import WatchtowerCore

extension ReviewComment {
    static func fixture(id: Int64, path: String?, start: Int, end: Int, anchor: CommentAnchor) -> ReviewComment {
        ReviewComment(id: id, roundID: 1, path: path, side: "new", startLine: start, endLine: end,
                      quote: anchor.quote, quotePrefix: anchor.prefix, quoteSuffix: anchor.suffix,
                      treeSHA: "t", lens: "", body: "b", status: .sent, carriedFrom: nil, agentReply: "")
    }
}
