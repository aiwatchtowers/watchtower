import SwiftUI
import AppKit
import WatchtowerCore

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Self.highlighted(code, language: language))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    static func highlighted(_ code: String, language: String?) -> AttributedString {
        CodeHighlighter.tokens(code, language: language).reduce(into: AttributedString()) { out, token in
            var part = AttributedString(token.text)
            switch token.kind {
            case .keyword: part.foregroundColor = Color(nsColor: .systemPurple)
            case .string: part.foregroundColor = Color(nsColor: .systemRed)
            case .comment: part.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .number: part.foregroundColor = Color(nsColor: .systemOrange)
            case .plain: break
            }
            out += part
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }
}
