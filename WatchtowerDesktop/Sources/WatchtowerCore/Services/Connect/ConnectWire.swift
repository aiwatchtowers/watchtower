import Foundation
import WatchtowerInterface

/// The Swift side of Go `internal/connectwire` (agent connect spec §5.3):
/// JSON lines over the per-run socket `ConnectRunServer` serves, a hello
/// line first, then one request and one response per connect tool call.
/// `internal/connectwire/testdata/wire_cases.json` pins every line shape;
/// `ConnectWireTests` decodes the same file.
package enum ConnectWire {
    /// The run's socket path and token reach `watchtower mcp --connect`
    /// through its environment, never its argv (Go `SocketEnv`, `TokenEnv`).
    package static let socketEnv = "WATCHTOWER_CONNECT_SOCKET"
    package static let tokenEnv = "WATCHTOWER_CONNECT_TOKEN"
    /// `ConnectWireHello.v` (Go `ProtocolVersion`).
    package static let protocolVersion = 1
    /// How long the Desktop holds a call that waits on the customer or a
    /// flow before it answers `{"state":"waiting"}` (Go `WaitBudget`). The
    /// MCP side's own deadline is Go `CallTimeout` (55 s), longer than this:
    /// the Desktop never waits as long as that.
    package static let waitBudget: Duration = .seconds(45)
    /// The longest line in either direction, its newline included (Go
    /// `MaxLine`: the client's scanner refuses a line of this many bytes).
    package static let maxLine = 1 << 20
    /// The hello refusal's message (wire case `hello_busy`).
    package static let busyMessage = "another assistant turn is still connected to this run"

    /// One value as a wire line: compact JSON and its newline.
    package static func line(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// An error code (Go `Code*`).
package enum ConnectWireError: String, Codable, CaseIterable, Sendable {
    case busy, policy, limit, declined, closed, failed
    case unknownTool = "unknown_tool"
    case badArgs = "bad_args"
}

/// A refused or failed call, or a refused hello (Go `Error`).
package struct ConnectWireFailure: Codable, Equatable, Sendable {
    package let code: ConnectWireError
    package let message: String

    package init(code: ConnectWireError, message: String) {
        self.code = code
        self.message = message
    }
}

/// The connection's first line, from the MCP server (Go `Hello`).
package struct ConnectWireHello: Codable, Equatable, Sendable {
    package let v: Int
    package let token: String
    package let service: String

    package init(v: Int = ConnectWire.protocolVersion, token: String, service: String) {
        self.v = v
        self.token = token
        self.service = service
    }
}

/// The answer to a hello (Go `HelloReply`): ok, or the `busy` refusal. A bad
/// hello gets no reply; the socket is closed.
package struct ConnectWireHelloReply: Codable, Equatable, Sendable {
    package let ok: Bool
    package let error: ConnectWireFailure?

    package static let admitted = Self(ok: true, error: nil)
    package static let busy = Self(ok: false, error: ConnectWireFailure(code: .busy, message: ConnectWire.busyMessage))

    package init(ok: Bool, error: ConnectWireFailure?) {
        self.ok = ok
        self.error = error
    }
}

/// One tool call (Go `Request`). `args` is the call's JSON object as is
/// (canonical: sorted keys).
package struct ConnectWireRequest: Codable, Equatable, Sendable {
    package let id: Int64
    package let tool: String
    package let args: Data

    private enum CodingKeys: String, CodingKey { case id, tool, args }

    package init(id: Int64, tool: String, args: Data) {
        self.id = id
        self.tool = tool
        self.args = args
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        tool = try container.decode(String.self, forKey: .tool)
        args = try container.decodeIfPresent(RawJSON.self, forKey: .args)?.data ?? Data("{}".utf8)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tool, forKey: .tool)
        try container.encode(RawJSON(data: args), forKey: .args)
    }
}

/// The answer to the request with the same id (Go `Response`): a result or
/// an error, the other left out.
package struct ConnectWireResponse: Codable, Equatable, Sendable {
    package let id: Int64
    package let result: RawJSON?
    package let error: ConnectWireFailure?

    package init(id: Int64, result: RawJSON) {
        self.id = id
        self.result = result
        error = nil
    }

    package init(id: Int64, error code: ConnectWireError, message: String) {
        self.id = id
        result = nil
        error = ConnectWireFailure(code: code, message: message)
    }

    /// A result given as JSON bytes; bytes that are not one JSON value
    /// become a `failed` error.
    package static func result(id: Int64, json: Data) -> Self {
        guard let raw = try? RawJSON(data: json) else {
            return Self(id: id, error: .failed, message: "the Watchtower app built an unreadable result")
        }
        return Self(id: id, result: raw)
    }

    /// The same answer under `id`: the socket answers each request under its
    /// own id whatever the handler put there.
    func answering(_ id: Int64) -> Self {
        Self(id: id, result: result, error: error)
    }

    private init(id: Int64, result: RawJSON?, error: ConnectWireFailure?) {
        self.id = id
        self.result = result
        self.error = error
    }
}
