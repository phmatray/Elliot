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

    /// The same file with every `//` comment cut away.
    ///
    /// ⚠️ **Load-bearing, and this repository walks into it every time.** These
    /// files *document* the rules the gates enforce — "no All repositories row",
    /// "the picker is not in the shared editor" — so a gate matching raw text
    /// fails on the explanation of the very rule it holds, and the obvious way to
    /// make it pass is to delete the explanation. Measured here rather than
    /// assumed: the first version of `thePickerHasNoAllRepositoriesRow` went red
    /// against an unmodified `NewStoryView.swift`, on its own ⚠️ paragraph.
    ///
    /// It cuts positives too, not only negatives. A gate asserting that the face
    /// *reads* `model.newStoryRefusal` would otherwise be satisfied by a comment
    /// that merely mentions it — prose passing for behaviour, which is the same
    /// error pointed the other way. CLAUDE.md states the general form from #186: a
    /// string gate over prose *"can tell neither a claim from a mention nor a live
    /// claim from a quoted one"*.
    ///
    /// Cutting at `//` would also cut one inside a string literal; none of the
    /// needles these gates use can occur after one.
    static func code(of file: String) throws -> String {
        try source(of: file)
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
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
