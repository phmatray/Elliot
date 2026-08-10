import Foundation
import Testing

@testable import ElliotModel

/// A pack that exists only in this suite. The catalogue's own four are pinned by
/// `MethodCatalogTests` (Task 2); what is under test here is the rule, not the data.
private func makePack(
    requirements: [ProjectRequirement],
    steps: [SkillKind: StepSpec] = [:]
) -> MethodPack {
    MethodPack(
        id: "fixture",
        displayName: "Fixture",
        summary: "A method that exists only in this suite.",
        plugin: .none,
        projectRequirements: requirements,
        steps: steps
    )
}

private func makeRequirement(_ id: String, _ evidence: MethodPack.Evidence) -> ProjectRequirement {
    ProjectRequirement(
        id: id,
        title: "The artefact \(id)",
        evidence: evidence,
        remedy: "Write it.",
        seed: CardDraft(
            title: "Write \(id)",
            role: "maintainer of this repository",
            want: "the artefact \(id) written down",
            benefit: "the method has the file it reads",
            criteria: ["The file exists."]
        )
    )
}

@Suite("Method pack")
struct MethodPackTests {
    @Test("A requirement whose evidence never reached the map is a gap")
    func absentEvidenceIsAGap() {
        // `ArtifactSweeper`'s rule, one screen over: a lookup that did not answer
        // must not read as a pass. Reporting a gap that is not there costs a
        // warning row; missing one costs the requirement.
        let pack = makePack(requirements: [makeRequirement("a", .file("A.md"))])
        #expect(pack.projectGaps(satisfied: [:]).map(\.id) == ["a"])
    }

    @Test("A requirement whose evidence is satisfied is not a gap")
    func satisfiedIsNotAGap() {
        let pack = makePack(requirements: [makeRequirement("a", .file("A.md"))])
        #expect(pack.projectGaps(satisfied: [.file("A.md"): true]).isEmpty)
    }

    @Test("False and absent are the same answer")
    func falseIsAGapToo() {
        let pack = makePack(requirements: [makeRequirement("a", .file("A.md"))])
        #expect(pack.projectGaps(satisfied: [.file("A.md"): false]).map(\.id) == ["a"])
    }

    @Test("Gaps keep the pack's own order, so two sweeps report the same list")
    func orderIsThePacks() {
        let pack = makePack(
            requirements: [
                makeRequirement("one", .file("One.md")),
                makeRequirement("two", .file("Two.md")),
                makeRequirement("three", .anyFileUnder("specs")),
            ]
        )
        #expect(pack.projectGaps(satisfied: [.file("Two.md"): true]).map(\.id) == ["one", "three"])
    }

    @Test("A pack with no project requirements has no gaps, whatever the map says")
    func noRequirementsNoGaps() {
        // ai-migration-kit's measured shape: it writes no artefact of its own.
        let pack = makePack(requirements: [])
        #expect(pack.projectGaps(satisfied: [:]).isEmpty)
        #expect(pack.projectGaps(satisfied: [.file("A.md"): false]).isEmpty)
    }

    @Test("The two evidence kinds are different keys, even on the same path")
    func evidenceKindsAreDistinctKeys() {
        // A probe that answered `.file("specs")` for `.anyFileUnder("specs")`
        // would be answering a different question — "there is a directory" is
        // not "there is something in it".
        let pack = makePack(requirements: [makeRequirement("dir", .anyFileUnder("specs"))])
        #expect(pack.projectGaps(satisfied: [.file("specs"): true]).map(\.id) == ["dir"])
    }

    /// ⛔ The most expensive correction in this plan, pinned where the key is built.
    @Test("The seeded-card key carries the repository, the pack and the requirement")
    func idempotencyKeyCarriesTheRepository() {
        // `card_on_idempotencyKey` is unique board-wide, not per repository —
        // `Migrations.swift:34-42` says so deliberately, and
        // `BoardStore.card(idempotencyKey:)` filters on the key alone. A
        // repo-free key means the SECOND repository to choose GSD is seeded
        // nothing, while `CheckFixOutcome` reports "Added a card to Backlog."
        // Task 9 is where that is watched end to end; this pins the string.
        let requirement = makeRequirement("gsd-project", .file(".planning/PROJECT.md"))
        let pack = makePack(requirements: [requirement])
        let a = UUID(), b = UUID()
        #expect(
            pack.idempotencyKey(for: requirement, in: a)
                == "method:\(a):fixture:req:gsd-project"
        )
        #expect(
            pack.idempotencyKey(for: requirement, in: a)
                != pack.idempotencyKey(for: requirement, in: b)
        )
    }

    @Test("A pack survives a Codable round trip, seeded cards and all")
    func codableRoundTrip() throws {
        // Wave 3 loads packs from `~/.elliot/methods/`. The conformance is
        // declared now so the shape cannot drift into something unserialisable
        // — and because `ProjectRequirement` carrying a `CardDraft` is what
        // forced `CardDraft: Codable` in the first place.
        let original = makePack(
            requirements: [
                makeRequirement("a", .file("A.md")),
                makeRequirement("b", .anyFileUnder("specs")),
            ],
            steps: [
                .createIssue: StepSpec(
                    command: "/x:create", arguments: .ideaThenLabels, prose: "File this: {}"
                ),
                .mergePR: StepSpec(
                    command: "/x:merge", arguments: .numberThenFollowUps, prose: "Land {}."
                ),
            ]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MethodPack.self, from: data) == original)
    }

    /// ⚠️ Measured, not assumed, and recorded so wave 3 meets it deliberately.
    @Test("steps encodes as an alternating array, which is not hand-writable JSON")
    func stepsEncodeAsAnAlternatingArray() throws {
        // A `String`-raw-value enum is **not** auto-conformed to
        // `CodingKeyRepresentable`, so `[SkillKind: StepSpec]` encodes as an
        // unkeyed array — `{"steps":["createIssue",{…}]}` — rather than an
        // object. Equality round-trips, so `codableRoundTrip` above cannot see
        // it. Nothing in wave 1 hand-writes a pack (the catalogue is compiled
        // in), so this is pinned rather than changed: wave 3's loader is where
        // conforming `SkillKind: CodingKeyRepresentable` belongs, and it must
        // be a deliberate act with its own migration of any file already
        // written in this shape.
        let pack = makePack(
            requirements: [],
            steps: [.createIssue: StepSpec(command: "/x:c", arguments: .none, prose: "go")]
        )
        let json = try #require(String(data: try JSONEncoder().encode(pack), encoding: .utf8))
        #expect(json.contains("[\"createIssue\","), "steps stopped encoding as an array: \(json)")
    }

    @Test("A step's argument form is a closed vocabulary, not a template")
    func argumentFormIsClosed() {
        // Pinned so a later task cannot quietly add a `.template(String)` case:
        // that is approach B, which was rejected for reopening a syntax, an
        // escaping and a validation that `SlashCommandBuilder.sanitized()`
        // already paid for.
        //
        // Five cases, not the four the plan originally specced: `.idea` was
        // added by amendment A1 after GSD's capture command was measured to
        // reject `--label`, which `.ideaThenLabels` would otherwise send it.
        // That is the sanctioned way this vocabulary grows — one case, with a
        // named reason — never a licence to add cases for convenience.
        //
        // ⚠️ `.none` is carried by the canonical contract and by **no built-in
        // pack** in wave 1, so nothing exercises it end to end. That is an
        // asymmetry with `Evidence`'s GitHub cases, which this plan refuses to
        // add early for exactly that reason. It is kept because the contract
        // fixes this enum's shape, and because inventing a `.none` step for a
        // method nobody measured would be worse — see Task 2's judgement calls.
        #expect(ArgumentForm.allCases.count == 5)
        #expect(
            Set(ArgumentForm.allCases.map(\.rawValue))
                == ["none", "idea", "ideaThenLabels", "number", "numberThenFollowUps"]
        )
    }
}
