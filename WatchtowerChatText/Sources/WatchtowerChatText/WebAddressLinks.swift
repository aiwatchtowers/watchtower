import Foundation

/// Web addresses written as plain text in prose become links: a full
/// `http(s)://…` URL, and a bare host with an optional port and path
/// (`api.slack.com/apps`, `console.cloud.google.com`), which opens as
/// `https://`. A bare host needs a top-level domain from `topLevelDomains`,
/// a short list of common ones that leaves out those that read as file
/// extensions (`notes.md`, `run.sh`, `app.py`, `Watchtower.app`), so file
/// names, version numbers (`1.2.3`) and mail addresses stay text. A bare
/// host of two labels with no port or path reads like code as often as like
/// a site (`logger.info`, `java.io`, `System.Net`, `self.page`): it links
/// only with a domain from `twoLabelDomains`. Trailing sentence punctuation,
/// closing quotes (`»`, `”`) and an unbalanced closing bracket stay outside
/// the link. Inline code, code blocks and existing links are never touched:
/// `MarkdownDocument` applies this to the text of headings, paragraphs and
/// table cells only.
public enum WebAddressLinks {
    /// The top-level domains a bare host may end in.
    static let topLevelDomains: Set<String> = [
        "com", "net", "org", "io", "dev", "ai", "co", "gov", "edu", "mil", "int", "info", "biz", "me", "tv", "cloud",
        "tech", "site", "online", "xyz", "page", "us", "uk", "de", "fr", "eu", "ca", "au", "nl", "se", "dk", "fi", "es",
        "ch", "at", "be", "jp", "cn", "kr", "br", "ua", "cz", "ie", "nz", "il", "sg", "hk", "tw", "za", "mx", "ar",
        "tr", "gr", "pt", "ro", "hu", "sk", "lt", "lv", "ee"
    ]

    /// The top-level domains a bare host of two labels alone (no port, no
    /// path) may end in: those no code identifier ends in.
    static let twoLabelDomains: Set<String> = ["com", "org", "edu", "gov", "mil"]

    // swiftlint:disable force_try
    /// A full URL, or a bare host (group 1: its last label) with an optional
    /// port and path; never inside a word, a path, an address or a URL.
    private static let candidate = try! NSRegularExpression(pattern:
        #"(?<![\w@./:\-])(?:https?://[^\s<>"'`]+|(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+([A-Za-z]{2,})"#
            + #"(?![\w@-])(?::\d{1,5})?(?:/[^\s<>"'`]*)?)"#,
        options: [.caseInsensitive])
    // swiftlint:enable force_try

    /// The addresses in `text`: each one's range and the URL it opens.
    public static func matches(in text: String) -> [(range: Range<String.Index>, url: String)] {
        let whole = NSRange(text.startIndex..., in: text)
        return candidate.matches(in: text, range: whole).compactMap { match in
            guard var range = Range(match.range, in: text) else { return nil }
            if let tld = Range(match.range(at: 1), in: text), !topLevelDomains.contains(text[tld].lowercased()) {
                return nil
            }
            range = range.lowerBound..<trimmedEnd(text[range])
            let address = text[range]
            guard let scheme = ["https://", "http://"].first(where: address.lowercased().hasPrefix) else {
                guard linksBare(address) else { return nil }
                return (range, "https://" + address)
            }
            // A scheme with no host after it is no address.
            guard address.dropFirst(scheme.count).contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return (range, String(address))
        }
    }

    /// A bare host links with a port or path, with three labels or more, or
    /// with two and a domain from `twoLabelDomains`.
    private static func linksBare(_ address: Substring) -> Bool {
        let host = address.prefix { $0 != ":" && $0 != "/" }
        guard host.endIndex == address.endIndex else { return true }
        let labels = host.split(separator: ".")
        return labels.count > 2 || twoLabelDomains.contains(labels.last?.lowercased() ?? "")
    }

    /// `inlines` with the addresses in their text as links, through
    /// emphasis; links and code are left as they are. Adjacent text pieces
    /// are read as one (the parser may split a sentence), and are kept as
    /// they were when they hold no address.
    public static func linked(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var texts: [String] = []
        func flushTexts() {
            guard !texts.isEmpty else { return }
            let joined = texts.joined()
            let found = matches(in: joined)
            if found.isEmpty {
                out += texts.map(MarkdownInline.text)
            } else {
                var cursor = joined.startIndex
                for (range, url) in found {
                    if cursor < range.lowerBound { out.append(.text(String(joined[cursor..<range.lowerBound]))) }
                    out.append(.link(destination: url, children: [.text(String(joined[range]))]))
                    cursor = range.upperBound
                }
                if cursor < joined.endIndex { out.append(.text(String(joined[cursor...]))) }
            }
            texts = []
        }
        for inline in inlines {
            if case let .text(value) = inline {
                texts.append(value)
                continue
            }
            flushTexts()
            switch inline {
            case let .emphasis(children): out.append(.emphasis(linked(children)))
            case let .strong(children): out.append(.strong(linked(children)))
            case let .strikethrough(children): out.append(.strikethrough(linked(children)))
            case .text, .code, .link, .lineBreak, .softBreak: out.append(inline)
            }
        }
        flushTexts()
        return out
    }

    /// The end of `address` without trailing sentence punctuation, closing
    /// quotes or a closing bracket it does not open. `_` and `~` are URL
    /// characters and stay (Markdown emphasis never reaches here as text).
    private static func trimmedEnd(_ address: Substring) -> String.Index {
        var end = address.endIndex
        while end > address.startIndex {
            let last = address[address.index(before: end)]
            let body = address[address.startIndex..<address.index(before: end)]
            let unbalanced: Bool = switch last {
            case ")": body.filter { $0 == "(" }.count < body.filter { $0 == ")" }.count + 1
            case "]": body.filter { $0 == "[" }.count < body.filter { $0 == "]" }.count + 1
            default: false
            }
            guard ".,;:!?*»”’›\"'".contains(last) || unbalanced else { break }
            end = address.index(before: end)
        }
        return end
    }
}
