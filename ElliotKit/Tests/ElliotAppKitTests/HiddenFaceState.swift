import Foundation

/// Reads the `@State` a view declares, for the gates that decide whether a hide
/// may destroy it.
///
/// ⚠️ **Two screens now need this and it is written once, deliberately.** The
/// board's slots are torn down when they are hidden — `PanelLayout.boardOrder`
/// drops the analysis panel, `ConsoleState.close` drops the console's face — so
/// "nothing the reader has typed may be `@State` here" is one invariant holding
/// over two subtrees. This repository has paid three defects for one mechanism
/// written twice (#146), and its own rule is sharper than that: *when the
/// explanation of an invariant has been copied word for word, the invariant has
/// been copied too.* So the **parse** lives here and the **judgement** does not:
/// each gate keeps its own allow-list and its own reasons, because what is safe
/// to lose is a judgement about that screen's data and no matcher can make it.
enum HiddenFaceState {

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    static func source(of file: String) throws -> String {
        try String(contentsOf: viewSources.appending(path: file), encoding: .utf8)
    }

    /// Every `@State private var` declared anywhere in a file, by name.
    ///
    /// ⚠️ **The whole file, not one `struct`.** The first version of this scan
    /// cut at a type boundary on the theory that a sub-view's state was its own
    /// business. It is not: hiding a slot destroys *every* view in the subtree,
    /// so a `@State` in a row, an editor or a tile is lost by exactly the same
    /// mechanism — and the narrow scan skipped two of the three views it claimed
    /// to cover, finding one of them only by accident of declaration order.
    static func declared(in file: String) throws -> [String] {
        try source(of: file)
            .components(separatedBy: "@State private var")
            .dropFirst()
            .compactMap { chunk in
                chunk.drop(while: \.isWhitespace)
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    .description
            }
    }
}
