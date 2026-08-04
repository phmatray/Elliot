import ElliotMCPKit
import Foundation
import MCP

// The MCP helper. Claude Code spawns it, it speaks stdio, and it translates
// every call into an IPC request to the running Elliot.
//
// It imports neither ElliotEngine nor ElliotProcess on purpose: it never spawns
// `claude` and never writes the database. That is what guarantees an agent
// moving a card and a person dragging one go through the same rules — the
// helper holds no copy of them.
//
// stdout is the protocol channel, so nothing may be printed to it. Diagnostics
// go to stderr, which Claude Code surfaces separately.

let server = await ElliotMCPServer().makeServer()
let transport = StdioTransport()

do {
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("elliot-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
