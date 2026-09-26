import Foundation

/// The helper's command line: `watchtower-ocr <file> [--pages 0,2,5]`.
public struct HelperArguments: Equatable, Sendable {
    public let path: String
    /// 0-based PDF pages to recognize; nil = every page (images ignore it).
    public let pages: [Int]?

    public init(path: String, pages: [Int]?) {
        self.path = path
        self.pages = pages
    }

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let usage = "usage: watchtower-ocr <file> [--pages 0,2,5]"

    /// Parses the arguments after the program name.
    public static func parse(_ args: [String]) throws -> Self {
        guard let path = args.first, !path.hasPrefix("--") else { throw UsageError(description: usage) }
        switch args.count {
        case 1:
            return Self(path: path, pages: nil)
        case 3 where args[1] == "--pages":
            return Self(path: path, pages: try parsePages(args[2]))
        default:
            throw UsageError(description: usage)
        }
    }

    private static func parsePages(_ list: String) throws -> [Int] {
        try list.split(separator: ",", omittingEmptySubsequences: false).map { item in
            guard let page = Int(item), page >= 0 else {
                throw UsageError(description: "invalid page \"\(item)\" in --pages; \(usage)")
            }
            return page
        }
    }
}
