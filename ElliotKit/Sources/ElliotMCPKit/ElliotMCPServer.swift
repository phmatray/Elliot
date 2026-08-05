import Foundation
import MCP

/// The MCP face of the board.
///
/// Every mutating tool goes through `BoardService` in the running app, so an
/// agent moving a card and a person dragging one are the same act, decided by
/// the same rule engine. This type holds no rules of its own: it publishes the
/// tools in `Tools/` and routes calls to them.
public struct ElliotMCPServer: Sendable {
    private let bridge: AppBridge

    public init(bridge: AppBridge = AppBridge()) {
        self.bridge = bridge
    }

    /// Every tool the helper serves. Adding one is adding a file and a line
    /// here — the list and the dispatch table cannot drift apart, because the
    /// second is derived from the first.
    private static let registry: [any BoardTool] = [
        ListCardsTool(),
        GetCardTool(),
        CreateCardTool(),
        MoveCardTool(),
        ListRunsTool(),
    ]

    public static let tools: [Tool] = registry.map(\.tool)

    /// `uniqueKeysWithValues` on purpose: two tools claiming one name is a
    /// build-time mistake that should stop the helper, not a silent shadowing
    /// that makes one of them unreachable.
    private static let byName: [String: any BoardTool] = Dictionary(
        uniqueKeysWithValues: registry.map { ($0.name, $0) }
    )

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let tool = Self.byName[name] else {
            return .failure(code: "unknown_tool", message: "No such tool: \(name)")
        }
        do {
            return try await tool.call(arguments ?? [:], bridge: bridge)
        } catch {
            return .failure(code: "internal_error", message: error.localizedDescription)
        }
    }
}

// MARK: - Wiring

public extension ElliotMCPServer {
    /// Builds the MCP server and attaches the tool handlers.
    func makeServer() async -> Server {
        let server = Server(
            name: "elliot",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await call(name: params.name, arguments: params.arguments)
        }
        return server
    }
}
