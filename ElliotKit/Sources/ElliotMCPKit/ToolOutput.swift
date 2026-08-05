import ElliotIPC
import Foundation
import MCP

// MARK: - Results
//
// Every tool answers in the same shape — one JSON text block, `isError` telling
// the agent whether to trust it — so an agent can parse a reply without knowing
// which tool it came from.

extension CallTool.Result {
    static func ok(_ fields: [String: Value]) -> CallTool.Result {
        CallTool.Result(content: [.text(text: json(fields), annotations: nil, _meta: nil)], isError: false)
    }

    static func failure(code: String, message: String, hint: String? = nil) -> CallTool.Result {
        var fields: [String: Value] = ["error": .string(code), "message": .string(message)]
        if let hint { fields["hint"] = .string(hint) }
        return CallTool.Result(content: [.text(text: json(fields), annotations: nil, _meta: nil)], isError: true)
    }

    /// Renders a response from the running app. A failure keeps the app's own
    /// code, message and hint: the helper never rewords a refusal it did not
    /// decide.
    static func render(
        _ response: ElliotResponse,
        _ body: (ElliotPayload) -> [String: Value]?
    ) -> CallTool.Result {
        switch response {
        case .failure(let code, let message, let hint):
            return .failure(code: code.rawValue, message: message, hint: hint)
        case .ok(let payload):
            guard let fields = body(payload) else {
                return .failure(code: "internal_error", message: "Unexpected response shape.")
            }
            return .ok(fields)
        }
    }

    private static func json(_ fields: [String: Value]) -> String {
        guard let data = try? WireCodec.encoder.encode(Value.object(fields)),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

extension Value {
    /// A wire DTO as an MCP value, through the wire codec — so what an agent
    /// reads over MCP is byte-for-byte what the IPC socket carries, dates
    /// included.
    static func encoding(_ value: some Encodable) -> Value {
        guard let data = try? WireCodec.encoder.encode(value),
              let decoded = try? WireCodec.decoder.decode(Value.self, from: data)
        else { return .null }
        return decoded
    }
}
