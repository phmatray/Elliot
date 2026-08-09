import Foundation

/// What a repository's `methodID` resolves to — in three values, because the
/// question has three answers.
///
/// An earlier draft of `Repo.method` read `MethodCatalog.pack(id: methodID) ??
/// .aiMigrationKit`. That is a **silent substitution**: a repository set to
/// `"gsd"` whose pack disappeared would run ai-migration-kit's commands, at
/// `bypassPermissions`, inside a real checkout, with nothing reporting it.
///
/// `PreflightState.notChecked`'s lesson verbatim — *a two-valued answer to a
/// three-valued question is how the gap hid for as long as it did.* "Never
/// chosen" and "chose something I do not know" are different facts.
///
/// ⚠️ **This type carries no verdict of its own.** `.unknown` is *intended* to
/// become a Preflight `.fail` that blocks moves and a `BoardService` refusal;
/// **Task 6 and Task 7 are what implement that**, and until they land nothing
/// acts on this case. Saying otherwise here would be the shape `PreflightState`'s
/// own header warns about: three documents asserting a gate nobody had written.
///
/// There is deliberately no `pack` convenience accessor. Callers switch
/// exhaustively, which is what makes `.unknown` impossible to skip past.
public enum MethodResolution: Sendable, Hashable {
    /// Never chosen. Carries ai-migration-kit, which is what every board ran
    /// before packs existed — the fold is the *absence* of a choice being given
    /// a meaning, not an unknown choice being overruled.
    case unset(MethodPack)
    case chosen(MethodPack)
    /// An id the catalogue does not know, carried so whoever reports it can name
    /// it. Naming the id is the entire point: "unknown" alone is unactionable.
    case unknown(String)
}

public extension MethodCatalog {
    /// Reads a stored id as one of the three answers.
    ///
    /// A blank id resolves to `.unset` rather than `.unknown("")`: SQLite can
    /// hold `''` — a picker that cleared the field writes one — and
    /// *"the method  is not known"* names nothing. Blank is the absence of a
    /// choice, which is exactly what `.unset` means.
    ///
    /// The id is **trimmed before lookup and before being reported**, so
    /// `"  gsd-2  "` answers `.unknown("gsd-2")`. Pinned by
    /// `MethodResolutionTests.unknownIsNamedRatherThanSubstituted`.
    static func resolve(_ id: String?) -> MethodResolution {
        guard let named = id?.trimmed(), !named.isEmpty else {
            // Unreachable in a shipped build — the catalogue is compiled in and
            // `MethodCatalogTests` pins this pack's presence — but a force
            // unwrap in a function every drag calls is not worth the two lines
            // saved, and `.unknown` at least names what went missing.
            guard let fallback = pack(id: defaultPackID) else {
                return .unknown(defaultPackID)
            }
            return .unset(fallback)
        }
        guard let chosen = pack(id: named) else { return .unknown(named) }
        return .chosen(chosen)
    }
}

/// File-scoped: the lookup `resolve` uses. Not public — a task that needs it
/// promotes it and says why.
private extension MethodCatalog {
    static func pack(id: String) -> MethodPack? {
        builtIn.first { $0.id == id }
    }
}
