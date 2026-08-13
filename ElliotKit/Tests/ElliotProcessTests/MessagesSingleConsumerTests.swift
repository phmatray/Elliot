import Foundation
import Testing

/// `Transport.messages` (`ACP/Transport/Transport.swift`) is an `AsyncStream` — single-consumer by
/// construction. Two iterators do not each see every value; they **split** what one producer
/// yields, roughly half to each. A second consumer would leave every other in-flight JSON-RPC
/// request silently timing out, with a green build and (absent this test) a green suite — a
/// dropped reply looks identical to a slow one until the timeout fires.
///
/// Modelled on `DrainDuplicationTests`: reads source text, not behaviour, because the failure mode
/// is a *second reader* agreeing with the first right up until it doesn't — no behavioural test can
/// see that from one process's worth of messages. `isCode()` is copied from there verbatim so prose
/// describing this very rule (there is plenty, in `Client.swift`'s own comments and in this file's)
/// cannot trip or satisfy the gate.
///
/// ## What this test does not see
///
/// This is a source-text gate, not a proof — it has a specific, known shape, not a general one.
/// Read a green run as "nothing matched this pattern," never as "no second consumer exists":
///
/// 1. **A second consumer inside `Client.swift` itself is invisible.** The exemption below is per
///    *file*, not per function — a debug drain or a peek-at-the-next-message helper added anywhere
///    else in that file would never be flagged, even though it is exactly the hazard this test
///    exists to catch.
/// 2. **`AsyncStream` is a value, and this gate keys on the acquisition site, not on how many times
///    the acquired value is iterated afterwards.** An exempted file can do
///    `let s = transport.messages` (that line is caught) and then hand `s` to a function or type in
///    another file, where the `for await` runs without the token `.messages` ever appearing there.
/// 3. **`Scripts/` is not scanned.** `messages` is `public` on a `public` protocol, and this
///    repository runs standalone Swift scripts (`Scripts/list-windows.swift`,
///    `Scripts/realclick.swift`, others) that could iterate it unseen.
/// 4. **The sanction keys on `lastPathComponent`.** A second file sharing `ACPTransportTests.swift`'s
///    bare name, anywhere else under the three scanned roots, would inherit its sanction unreviewed.
///
/// A fifth, found by break-testing this gate a second way after its own break-test (below) had
/// already passed once: a second consumer **inside `ACPTransport.swift`**, referencing the property
/// bare (`for await _ in messages { ... }` — no `self.` and no named receiver) rather than through
/// `self.` or a local variable, does not trip this gate. It matches the literal substring
/// `.messages` — a receiver followed by the property name — and a bare reference from inside the
/// declaring type has no receiver to match.
@Suite("Messages single consumer")
struct MessagesSingleConsumerTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)  // …/Tests/ElliotProcessTests/MessagesSingleConsumerTests.swift
            .deletingLastPathComponent()  // …/Tests/ElliotProcessTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
    }

    private static func swiftFiles(under directory: String) -> [URL] {
        let root = packageRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// A line with its comment forms stripped, so a gate about code cannot be tripped — or
    /// satisfied — by prose describing it.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    /// Files sanctioned to read `.messages` outside `Client.swift`, each with the reason it is not
    /// a second reader of a transport a `Client` is also reading — the same (name, reason) shape
    /// `DrainDuplicationTests.sanctionedShapes` uses, deliberately not narrowed further: this file's
    /// own dictionary literal below contains the text `.messages` too, which is why it excludes
    /// itself by name rather than by trying to out-clever its own search string.
    static let sanctionedConsumers: [String: String] = [
        "ACPTransportTests.swift": """
            Iterates `.messages` on an `ACPTransport` it just constructed, once per test, to prove \
            the transport's own line-framing (`/bin/cat` round-trips, split writes reassemble, \
            `close()` ends the stream). Never an instance any `Client` is also reading — no `Client` \
            exists in that file at all.
            """,
    ]

    /// This file's own name, excluded from the walk. It scans `Tests/`, which is where it lives,
    /// and its `sanctionedConsumers` reasons above are themselves code containing `.messages` —
    /// without this, the guard would flag itself.
    private static let ownFileName = "MessagesSingleConsumerTests.swift"

    @Test("nothing outside Client.swift consumes a transport's messages")
    func nothingOutsideConsumesMessages() throws {
        var offenders: [String] = []
        let files =
            Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Tests")
            + Self.swiftFiles(under: "Vendor")
        for file in files {
            let name = file.lastPathComponent
            guard name != "Client.swift", name != Self.ownFileName,
                Self.sanctionedConsumers[name] == nil
            else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let hit = text.components(separatedBy: "\n").contains {
                Self.isCode($0) && $0.contains(".messages")
            }
            if hit { offenders.append(name) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) reads `.messages` outside Client.swift. A second \
            consumer of a live transport splits its AsyncStream between iterators instead of each \
            seeing every value — a dropped JSON-RPC reply, not a slow one. Route it through Client, \
            or add an entry to sanctionedConsumers naming the file and the reason it is not reading \
            a transport a Client is also reading (see #146 for what happens when a mechanism like \
            this one is quietly duplicated — and this file's own doc comment for the shapes this \
            check does not see).
            """
        )
    }
}
