import SwiftUI

/// Informational screen for the read-only Watchtower MCP server.
/// It does not run the server — an external MCP client spawns `watchtower mcp`.
/// This screen only helps the user wire it up.
struct MCPServerView: View {
    private let claudeSnippet = "claude mcp add watchtower -- watchtower mcp"
    private let jsonSnippet = """
    {
      "mcpServers": {
        "watchtower": {
          "command": "watchtower",
          "args": ["mcp"]
        }
      }
    }
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MCP Server")
                    .font(.largeTitle).bold()
                Text("Expose your Watchtower data (read-only) to any MCP client — Claude Code, Cursor, Codex — so it can use your targets, briefings, digests, people, tracks, calendar, and Jira as work context.")
                    .foregroundStyle(.secondary)

                snippetBlock(title: "Add to Claude Code", text: claudeSnippet)
                snippetBlock(title: "Add to .mcp.json", text: jsonSnippet)

                Text("The server reads the same database as the app. It is read-only — no tool can modify your data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func snippetBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy config", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
