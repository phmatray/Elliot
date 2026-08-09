import Foundation
import Testing

@testable import ElliotModel

/// Three values, because the question has three answers.
///
/// An earlier draft of the accessor read `MethodCatalog.pack(id:) ?? .aiMigrationKit`.
/// That is a **silent substitution**: a repository set to `"gsd"` whose pack
/// disappeared would run ai-migration-kit's commands, at `bypassPermissions`,
/// inside a real checkout, with nothing reporting it. `PreflightState.notChecked`'s
/// lesson applied one type over — *a two-valued answer to a three-valued question
/// is how the gap hid for as long as it did* (#249).
@Suite("Resolving a method id")
struct MethodResolutionTests {
    @Test("A repository that never chose resolves to ai-migration-kit, and says it never chose")
    func unsetIsAiMigrationKit() {
        guard case .unset(let pack) = MethodCatalog.resolve(nil) else {
            Issue.record("nil resolved to \(MethodCatalog.resolve(nil)), not .unset")
            return
        }
        // Today's behaviour for every repository already registered: the packs
        // feature must be a refactor for them, not a change of method.
        #expect(pack.id == MethodCatalog.defaultPackID)
    }

    /// SQLite can hold `''` — a picker that cleared the field writes one — and
    /// `.unknown("")` would report *"the method  is not known"*, naming nothing.
    /// Blank is not a choice; it is the absence of one.
    @Test(
        "A blank id reads as never chosen, not as an unknown method named nothing",
        arguments: ["", "   ", "\n", "\t "]
    )
    func blankIsUnset(id: String) {
        guard case .unset = MethodCatalog.resolve(id) else {
            Issue.record("\(String(reflecting: id)) resolved to \(MethodCatalog.resolve(id))")
            return
        }
    }

    @Test("Every built-in pack resolves to itself, as a chosen one")
    func everyBuiltInResolvesToItself() {
        #expect(!MethodCatalog.builtIn.isEmpty, "an empty catalogue would make this test vacuous")
        for pack in MethodCatalog.builtIn {
            #expect(MethodCatalog.resolve(pack.id) == .chosen(pack))
        }
    }

    @Test("An id the catalogue does not know is named, never substituted")
    func unknownIsNamedRatherThanSubstituted() {
        #expect(MethodCatalog.resolve("gsd-2") == .unknown("gsd-2"))
        // A near-miss is a repository pointing at a pack we do not have, not a
        // typo to be forgiven: coercing it would run another method's commands.
        #expect(MethodCatalog.resolve("GSD") == .unknown("GSD"))
        // ⚠️ The id is reported **trimmed**, because that is the value `resolve`
        // looked up. Pinned so a reader knows which spelling reaches the screen.
        #expect(MethodCatalog.resolve("  gsd-2  ") == .unknown("gsd-2"))
    }
}
