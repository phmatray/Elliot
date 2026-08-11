import Foundation
import Testing

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
    ///
    /// ⚠️ **That last clause is weaker than it reads, and one caller has already
    /// left the range it was written for.** It is safe for a *structural* needle —
    /// `selectedRepoID`, `message.fixes` — which no plausible line puts after a
    /// `//`. ``UnattendedStartDelegationTests`` sweeps whole English sentences, and
    /// a source line ending `// … "This repository is switched off in Preflight."`
    /// would be cut and the copy missed. The failure direction is a false
    /// **negative** — a gate that misses a duplication, not one that invents it —
    /// which is why it is a caveat rather than a defect, and why the sentence
    /// gates also assert a positive witness (the rule's own file must still hold
    /// each sentence exactly once).
    static func code(of file: String) throws -> String {
        stripped(try source(of: file))
    }

    /// The cut itself, for a gate reading a file this enum does not resolve.
    ///
    /// ``UnattendedStartDelegationTests`` sweeps the whole of `Sources/` rather
    /// than one module's directory, and needs exactly this cut — measured, not
    /// assumed: `RunsPane.swift` documents *"a card whose repository is switched
    /// off in Preflight"*, which is one of the two sentences that gate claims has
    /// a single home. Written once here for the reason the header gives: a
    /// mechanism written twice has already cost this repository three defects.
    static func stripped(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The same file with **whole comment lines dropped** and every other line
    /// left intact — the second opinion ``code(of:)`` needs.
    ///
    /// ⚠️ **It exists because the cut above can hide code, which was measured
    /// rather than reasoned about.** ``stripped(_:)`` cuts at the first `//` on a
    /// line, including one inside a string literal, and licenses that with *"none
    /// of the needles these gates use can occur after one"*. Two callers' needles
    /// can: a real `.toolbar { Button("Start auto-dev") … }` written after
    /// `"https://ops"` on one line is invisible to the cut, compiles, and leaves
    /// the whole suite green. So a whole-file negative is checked against **both**
    /// readings and holds only where they agree — `DefaultActionTests.isCode`'s
    /// rule (a line is code unless it *starts* with `//`) used as a second
    /// opinion rather than as a replacement.
    ///
    /// ⛔ The trade, stated so it is a rule rather than a surprise: **prose about
    /// a needle any gate uses must live on its own comment line, not trailing a
    /// line of code.** A whole-line comment is dropped by this reading and cut by
    /// the other, so an explanation stays free either way.
    ///
    /// ⚠️ **Negatives only.** This reading keeps a trailing comment's text, so a
    /// *positive* needle checked against it can be satisfied by prose beside
    /// code, which is the mention-for-a-claim error pointed the other way.
    /// Callers assert positives against ``code(of:)``.
    ///
    /// Written here rather than in a suite for the reason the header gives, and
    /// because it now has two callers: `OperationsBandOrderTests` introduced it
    /// and `BoardAccessibilityTests` needs exactly the same second opinion over
    /// the same file. #146 charges three defects to one mechanism written twice,
    /// and its sharper form applies squarely — the ⚠️ above would have been the
    /// paragraph copied.
    static func codeLines(of file: String) throws -> String {
        try source(of: file)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// One function's body, by brace matching from its signature.
    ///
    /// ⚠️ **The fourth copy of this walk is the reason it is here, and three of
    /// them remain.** `AnalysisRefusalTests`, `AnalysisPanelViewSourceTests` and
    /// `AnalysisReviewRowTests` each carry their own; measured while adding this,
    /// the first two are byte-identical to it and the third is **not** (twenty
    /// lines against eighteen), so it needs reading rather than assuming. Folding
    /// them in also means editing `AnalysisRefusalTests`, whose byte-identity is
    /// live evidence for the change that introduced this helper. So: new gates
    /// reach for this one, the count stops growing, and consolidating the three is
    /// named as its own change rather than done half-way inside a fix round.
    ///
    /// Honest only where the target function holds no brace inside a string
    /// literal, and comments are expected to be cut already — the callers point it
    /// at `decide`, `reason` and `footer`, none of which do.
    ///
    /// ⚠️ **`signature` must stop short of the function's own opening `{`.**
    /// The walk starts at `signature`'s end and returns as soon as depth
    /// returns to zero, so it assumes the *first* `{` it meets is the
    /// function's own. Measured while adding a fifth caller
    /// (`AutoDevLaunchOrderShapeTests`, over `AppModel.start()`): passing the
    /// signature *with* its trailing `{` — the shape a hand-rolled walk
    /// elsewhere in this tree (`RunSchedulerShapeTests`, a different
    /// algorithm entirely) does use — made this helper read `start()`'s first
    /// `guard store == nil else { return }` as the whole function and return
    /// eight characters, `" return "`, instead of the ~200-line body. Every
    /// existing caller already stops short (`"private func adopt("`,
    /// `"struct AutoDevBand: Equatable"`, `"private var autoDevBand: some
    /// View"`, …); this is written down so the next one does not have to
    /// rediscover it by watching three tests fail with `nil` needles that
    /// are plainly present in the source.
    static func body(of signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        var depth = 0
        var open: String.Index?
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                if depth == 0 { open = source.index(after: index) }
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0, let open { return String(source[open..<index]) }
            }
            index = source.index(after: index)
        }
        Issue.record("no matching brace for \(signature)")
        return ""
    }

    /// How many braces deep the first occurrence of `needle` sits inside
    /// `block`, or `nil` if it does not occur there at all.
    ///
    /// The structural half of a presence gate, and worth having beside a needle
    /// because it answers about the **shape** of the code rather than about its
    /// vocabulary: an `if` written around the call reddens whatever that `if`
    /// tests — `controls.isEmpty`, a tally threshold, a condition nobody has
    /// thought of yet — where a banned-word list only ever holds the words on it.
    ///
    /// ⛔ **What it is not.** This doc said *"a `ViewBuilder` cannot return early,
    /// so every way of not drawing something is a brace"*. That is false, and
    /// **three** evasions have now been measured green against gates built on it:
    ///
    /// 1. a **braceless ternary** — `(cond ? AnyView(EmptyView()) : AnyView(x))`
    ///    — no brace between the guard and the call, so the depth is unchanged;
    /// 2. a **sibling-function guard** — an overload whose own body holds the
    ///    `if`, leaving the call site byte-identical bar one argument and the
    ///    branch outside the slice entirely;
    /// 3. a **modifier that draws nothing**, *inside* the correct branch —
    ///    `.opacity(0)`, `.hidden()`, a zero `font` or `frame`. The view is
    ///    present, the depth is right, and there is nothing on screen. Measured
    ///    while fixing `AutoDevCardMarkTests`: `.opacity(activeRun == nil ? 1 : 0)`
    ///    on the engaged card's mark restored the exact defect that suite exists
    ///    to prevent, with **2628 tests in 300 suites green**.
    ///
    /// So this is a guarantee against a **brace-shaped branch inside the block it
    /// is handed**, and nothing wider. A caller that needs the other three says
    /// so in its own words, because the shapes differ per surface — the pattern
    /// worth copying is `BoardAccessibilityTests`', which bans `.hidden()` and
    /// `.opacity(` in the strip's body *beside* its depth check, and which both
    /// modifier breaks above reddened on.
    ///
    /// ⚠️ **The false sentence had already been retired once on this branch** —
    /// in `BoardAccessibilityTests`, two commits before this helper existed — and
    /// was then written again here. A universal is the premise the next author
    /// reasons from, so it is the one kind of comment worth measuring before
    /// writing.
    ///
    /// ⚠️ **The second copy of this walk, and the first is `BoardAccessibility
    /// Tests.braceDepth`.** Written here rather than a third time, on the
    /// precedent ``body(of:in:)`` sets four doc comments up: new gates reach for
    /// the shared one, the count stops growing, and folding the existing private
    /// copy in is named as its own change — that copy is live evidence for the
    /// commit that introduced it, so editing it inside an unrelated task is
    /// exactly the half-way consolidation that comment warns against.
    ///
    /// Honest only where the block holds no brace inside a string literal, and
    /// comments are expected to be cut already — the same bound ``body(of:in:)``
    /// carries, for the same reason.
    static func braceDepth(of needle: String, in block: String) -> Int? {
        var depth = 0
        var index = block.startIndex
        while index < block.endIndex {
            if block[index...].hasPrefix(needle) { return depth }
            if block[index] == "{" { depth += 1 }
            if block[index] == "}" { depth -= 1 }
            index = block.index(after: index)
        }
        return nil
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
