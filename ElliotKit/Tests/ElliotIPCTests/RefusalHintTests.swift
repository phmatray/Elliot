// Plain `import`, deliberately, where this target's neighbours use `@testable`:
// the whole point of these words is that two *other* targets read them, so the
// test has to see exactly what `ElliotEngine` and `ElliotMCPKit` see. Under
// `@testable` an internal `RefusalHint` would satisfy this suite and fail both
// consumers — which is the one mistake a test of a shared constant can make.
import ElliotIPC
import ElliotModel
import Testing

@Suite("Refusal hints")
struct RefusalHintTests {

    /// Pinned as a literal rather than compared to itself.
    ///
    /// The text is the interface here: an agent reads it and picks its next
    /// call from it, so a rename that silently changed the tool it names would
    /// be a behaviour change wearing the clothes of a refactor.
    ///
    /// Restored verbatim, and the provenance is worth stating exactly because
    /// the obvious guess is wrong: the string never lived in
    /// `OfflineResponder.swift` — that file was *created* by #144 — but in
    /// `ElliotMCPKit/Tools/ListRunsTool.swift:113`, added by `c372f99` (#20)
    /// and removed by `39b977e` (#144). `git log -S` over `OfflineResponder`
    /// returns nothing, so a reader checking a comment that named it would
    /// conclude the words were invented rather than recovered.
    @Test("card_not_found points at the tool that lists card ids")
    func cardNotFoundNamesListCards() {
        #expect(RefusalHint.cardNotFound == "board_list_cards lists the cards this board holds.")
    }

    // MARK: - repo_not_found (#219)

    /// The parameterised sibling. It is a factory rather than a constant, so
    /// what is pinned is the whole refusal — code, message and hint — because
    /// that is the unit the two callers used to assemble separately.
    ///
    /// Pinned as literals for the same reason as above: an agent reads these
    /// words and picks its next call from them. And pinned *here*, in the target
    /// that owns them, because the parity test in `ElliotEngineTests` proves the
    /// two paths **agree** — which stays true if both are reworded together, and
    /// a silent reword is exactly what this suite is for.
    private func repos() -> [Repo] {
        [
            Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"),
            Repo(path: "/tmp/koine", nameWithOwner: "Atypical-Consulting/Koine", displayName: "Koine"),
        ]
    }

    @Test("repo_not_found names what was asked for and lists what exists")
    func repoNotFoundIsOneWholeRefusal() throws {
        let response = ElliotResponse.repoNotFound(name: "phmatray/Eliot", in: repos())

        guard case .failure(let code, let message, let hint) = response else {
            Issue.record("repoNotFound must be a refusal, not an ok payload")
            return
        }
        #expect(code == .repoNotFound)
        #expect(message == "No registered repository matches \"phmatray/Eliot\".")
        #expect(hint == "Known: phmatray/Elliot, Atypical-Consulting/Koine")
    }

    /// An empty board still answers, and says so by listing nothing rather than
    /// by omitting the hint. `hint == nil` would read as "no advice available";
    /// an empty list reads as "none are registered", which is the actual state
    /// and the one a first-run agent meets.
    @Test("repo_not_found on an empty board keeps its hint and empties the list")
    func repoNotFoundWithNoReposStillHints() throws {
        let response = ElliotResponse.repoNotFound(name: "anything", in: [])

        guard case .failure(_, _, let hint) = response else {
            Issue.record("repoNotFound must be a refusal, not an ok payload")
            return
        }
        #expect(hint == "Known: ")
    }

    /// The separator is part of the interface: an agent splits this list.
    @Test("repo_not_found joins known repositories with a comma and a space")
    func repoNotFoundJoinsWithCommaSpace() throws {
        let response = ElliotResponse.repoNotFound(name: "x", in: repos())

        guard case .failure(_, _, let hint) = response else {
            Issue.record("repoNotFound must be a refusal, not an ok payload")
            return
        }
        let listed = try #require(hint?.dropFirst("Known: ".count))
        #expect(listed.components(separatedBy: ", ").count == 2)
    }
}
