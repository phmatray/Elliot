import Foundation
import Testing

@testable import ElliotModel

/// The path a piece of evidence points at, whichever kind it is.
private func path(of evidence: MethodPack.Evidence) -> String {
    switch evidence {
    case .file(let p), .anyFileUnder(let p): p
    }
}

/// What each pack is declared to carry — written out by hand rather than derived
/// from the packs themselves, which would assert nothing. A step that disappears
/// fails here instead of at someone's first drag, and a new `SkillKind` forces
/// four deliberate answers rather than four silent absences.
private let declaredSteps: [String: Set<SkillKind>] = [
    // Today's method, unchanged: the three transitions Elliot has always driven.
    "ai-migration-kit": [.createIssue, .implementIssue, .mergePR],
    // Captures the idea as a tracked todo. Amendment A3: `/gsd-plan-phase` and
    // `/gsd-ship` both take a *phase* number resolved against ROADMAP.md, where
    // Elliot holds an issue number at To Do and a PR number at Done — different
    // objects, so neither transition is wired in wave 1.
    "gsd": [.createIssue],
    // `/speckit.specify <description>` only. The plan/tasks/implement chain is
    // several commands per transition, and `/speckit.taskstoissues` fans one
    // feature out to N issues — out of scope for wave 1's cardinality.
    "speckit": [.createIssue],
    // Produces no GitHub object at all, so there is nothing for `Verifier` to
    // confirm until wave 2's file-backed transition evidence exists.
    "bmad": [],
]

@Suite("Built-in method catalogue")
struct MethodCatalogTests {
    @Test("The catalogue is the four packs, in the order the picker shows them")
    func theFourPacks() {
        #expect(MethodCatalog.builtIn.map(\.id) == ["ai-migration-kit", "gsd", "speckit", "bmad"])
        // The one literal, tied to the pack it names.
        #expect(MethodCatalog.defaultPackID == "ai-migration-kit")
        #expect(MethodCatalog.aiMigrationKit.id == MethodCatalog.defaultPackID)
    }

    @Test("Ids are unique — Repo.methodID stores one and must resolve to one pack")
    func idsAreUnique() {
        #expect(Set(MethodCatalog.builtIn.map(\.id)).count == MethodCatalog.builtIn.count)
        for pack in MethodCatalog.builtIn {
            #expect(!pack.id.isEmpty)
            #expect(!pack.displayName.isEmpty, "\(pack.id) has no display name")
            #expect(!pack.summary.isEmpty, "\(pack.id) has nothing to show in the picker")
        }
    }

    @Test("Every seeded card's idempotency key is unique across the whole catalogue")
    func idempotencyKeysAreUnique() {
        // ⛔ Built through the SAME function Preflight seeds with
        // (`MethodPack.idempotencyKey(for:in:)`), not through a format string
        // repeated here: an assertion about a shape no code produces cannot
        // fail, and the previous draft of this test had exactly that defect.
        let repoID = UUID()
        let keys = MethodCatalog.builtIn.flatMap { pack in
            pack.projectRequirements.map { pack.idempotencyKey(for: $0, in: repoID) }
        }
        #expect(!keys.isEmpty, "no pack declares a project requirement — the wave has no consumer")
        #expect(Set(keys).count == keys.count, "duplicate seeded-card keys among \(keys)")
        // And the repository is genuinely in them, which is what stops the second
        // repository to choose a method finding the first one's card.
        #expect(keys.allSatisfy { $0.contains(repoID.uuidString) })
    }

    @Test("Evidence paths are relative to the checkout and never escape it")
    func pathsStayInsideTheCheckout() {
        // Refused where the catalogue is validated, not at probe time: wave 1's
        // packs are compiled in. Wave 3's loader needs this as a runtime check.
        for pack in MethodCatalog.builtIn {
            for requirement in pack.projectRequirements {
                let p = path(of: requirement.evidence)
                let where_ = "\(pack.id)/\(requirement.id)"
                #expect(!p.isEmpty, "\(where_) points at nothing")
                #expect(!p.hasPrefix("/"), "\(where_) is absolute: \(p)")
                #expect(!p.hasPrefix("~"), "\(where_) is a home path: \(p)")
                #expect(
                    !p.split(separator: "/").contains(".."),
                    "\(where_) escapes the checkout: \(p)"
                )
            }
        }
    }

    @Test("Every SkillKind is either carried or explicitly absent, for every pack")
    func everyKindIsAnswered() {
        #expect(Set(declaredSteps.keys) == Set(MethodCatalog.builtIn.map(\.id)))
        for pack in MethodCatalog.builtIn {
            let declared = declaredSteps[pack.id] ?? []
            for kind in SkillKind.allCases {
                #expect(
                    (pack.steps[kind] != nil) == declared.contains(kind),
                    "\(pack.id) disagrees with the table about \(kind.skillName)"
                )
            }
        }
    }

    @Test("ai-migration-kit runs exactly the commands Elliot has always run")
    func aiMigrationKitCommands() {
        let pack = MethodCatalog.aiMigrationKit
        #expect(pack.steps[.createIssue]?.command == "/ai-migration-kit:create-issue")
        #expect(pack.steps[.implementIssue]?.command == "/ai-migration-kit:implement-issue")
        #expect(pack.steps[.mergePR]?.command == "/ai-migration-kit:merge-pr")
        #expect(pack.steps[.createIssue]?.arguments == .ideaThenLabels)
        #expect(pack.steps[.implementIssue]?.arguments == .number)
        #expect(pack.steps[.mergePR]?.arguments == .numberThenFollowUps)
        // Measured: this method writes no artefact of its own. Zero is a fact
        // about the method, not a pack somebody left half-written.
        #expect(pack.projectRequirements.isEmpty)
    }

    /// ⛔ The literal, pinned. `commandsAreWellFormed` below only checks shape, so
    /// without this a rename of `/gsd-capture` leaves every test green — while by
    /// this plan's own argument a wrong command starts an unattended `claude -p`
    /// at `bypassPermissions`.
    ///
    /// Amendment A3, not the original brief: the plan's first draft bound this to
    /// `/gsd-plan-phase` with `.ideaThenLabels`, and both halves were wrong —
    /// wrong command (`/gsd-plan-phase [N]` and `/gsd-ship [N]` take a *phase*
    /// number, not the issue/PR numbers Elliot's other transitions hold), and a
    /// `--label` tail `/gsd-capture` does not parse (measured: it documents
    /// `--note`, `--backlog`, `--seed`, `--list`, no `--label`).
    @Test("GSD's one declared command is the capture one")
    func gsdCommands() {
        let pack = MethodCatalog.gsd
        #expect(pack.steps[.createIssue]?.command == "/gsd-capture")
        #expect(pack.steps[.createIssue]?.arguments == .idea)
    }

    @Test("Spec Kit's one declared command is specify")
    func speckitCommands() {
        let pack = MethodCatalog.speckit
        #expect(pack.steps[.createIssue]?.command == "/speckit.specify")
        #expect(pack.steps[.createIssue]?.arguments == .ideaThenLabels)
    }

    /// ⛔ A wrong path makes Preflight seed a card that can never be satisfied.
    @Test("The project-artefact paths are the ones these methods actually write")
    func requirementPathsArePinned() {
        func paths(_ pack: MethodPack) -> [String] {
            pack.projectRequirements.map { path(of: $0.evidence) }
        }
        #expect(
            paths(MethodCatalog.gsd)
                == [".planning/PROJECT.md", ".planning/REQUIREMENTS.md", ".planning/ROADMAP.md"]
        )
        #expect(paths(MethodCatalog.speckit) == [".specify", "specs"])
        #expect(paths(MethodCatalog.bmad) == ["docs/prd.md", "docs/ARCHITECTURE-SPINE.md"])
        // The kind matters as much as the path: `.specify` and `specs` are
        // directories that must contain something, not directories that exist.
        for requirement in MethodCatalog.speckit.projectRequirements {
            guard case .anyFileUnder = requirement.evidence else {
                Issue.record("\(requirement.id) is not .anyFileUnder")
                continue
            }
        }
    }

    @Test("ai-migration-kit's prose is today's fallback sentence, slot and all")
    func aiMigrationKitProse() {
        // The byte-for-byte identity of the built *prompts* is `GoldenPromptTests`'
        // job — created by Task 4, once the builder takes a pack. This pins the
        // ingredient: the same sentences, with `{}` where the interpolation was.
        let pack = MethodCatalog.aiMigrationKit
        #expect(
            pack.steps[.createIssue]?.prose
                == "Use the create-issue skill to file a GitHub issue for this user story: {}"
        )
        #expect(
            pack.steps[.implementIssue]?.prose
                == "Use the implement-issue skill on issue {}: execute its implementation "
                + "plan and open a pull request."
        )
        #expect(pack.steps[.mergePR]?.prose == "Use the merge-pr skill to land pull request {}.")
    }

    @Test("A step carrying a payload has exactly one slot; one carrying none has no slot")
    func proseSlots() {
        for pack in MethodCatalog.builtIn {
            for (kind, step) in pack.steps {
                let slots = step.prose.components(separatedBy: "{}").count - 1
                let expected = step.arguments == ArgumentForm.none ? 0 : 1
                #expect(
                    slots == expected,
                    "\(pack.id)/\(kind.skillName) has \(slots) slots for \(step.arguments)"
                )
            }
        }
    }

    @Test("Every command is one slash-prefixed word")
    func commandsAreWellFormed() {
        // Whitespace in a command would put the payload after an argument the
        // pack never declared — the escaping is the builder's, the shape is ours.
        for pack in MethodCatalog.builtIn {
            for (kind, step) in pack.steps {
                let where_ = "\(pack.id)/\(kind.skillName)"
                #expect(step.command.hasPrefix("/"), "\(where_): \(step.command)")
                #expect(step.command.count > 1, "\(where_) has an empty command")
                #expect(
                    !step.command.contains(where: { $0.isWhitespace }),
                    "\(where_) has whitespace in \(step.command)"
                )
            }
        }
    }

    @Test("Every seeded card is complete enough to be saved and then dragged")
    func seedsAreSaveable() {
        // A seed failing `isValid` would be seeded by Preflight and refused by
        // `evaluateMove`'s incompleteStory guard at the first drag — a card the
        // board created and will not move.
        for pack in MethodCatalog.builtIn {
            for requirement in pack.projectRequirements {
                let where_ = "\(pack.id)/\(requirement.id)"
                #expect(!requirement.title.isEmpty, "\(where_) has no title")
                #expect(!requirement.remedy.isEmpty, "\(where_) offers no remedy")
                #expect(requirement.seed.isValid, "\(where_) seeds a card that cannot be saved")
                #expect(
                    requirement.seed.story?.isComplete == true,
                    "\(where_) seeds a half-written story"
                )
            }
        }
    }

    @Test("GSD carries project requirements and says only its first transition runs anything")
    func gsdSaysWhatItDoesNotCarry() {
        let gsd = MethodCatalog.gsd
        #expect(!gsd.projectRequirements.isEmpty)
        #expect(Set(gsd.steps.keys) == [.createIssue])
        #expect(
            gsd.summary.contains("only its capture step"),
            "a method wiring only one transition must say so where it is chosen: \(gsd.summary)"
        )
    }

    @Test("BMAD carries project requirements, no steps, and says so in its own summary")
    func bmadIsRequirementsOnly() {
        let bmad = MethodCatalog.bmad
        #expect(!bmad.projectRequirements.isEmpty)
        #expect(bmad.steps.isEmpty)
        #expect(
            bmad.summary.contains("no board steps"),
            "a method that cannot move a card must say so where it is chosen: \(bmad.summary)"
        )
    }

    // MARK: - PluginRequirement (amendment A2)

    /// Retires `unmeasuredPluginsAreNamed`: A2 replaced the two-valued
    /// `pluginName: String?` with a three-valued `PluginRequirement`, so the
    /// conflation that test existed to record ("nil means either 'not a plugin'
    /// or 'nobody looked'") can no longer happen — the type says which.
    @Test("Every pack's plugin requirement is exactly what was measured")
    func pluginRequirementsMatchMeasurement() {
        // ai-migration-kit ships as a plugin under its own id — what
        // `PreflightService` checks today.
        #expect(MethodCatalog.aiMigrationKit.plugin == .required(MethodCatalog.defaultPackID))
        // GSD's and Spec Kit's nil are both the contract's meaning, measured, not
        // a stand-in for "nobody looked": GSD's official `--claude` mode and Spec
        // Kit's `specify init` both write straight into the checkout — neither is
        // a Claude Code plugin, and neither has a marketplace entry.
        #expect(MethodCatalog.gsd.plugin == .none)
        #expect(MethodCatalog.speckit.plugin == .none)
        // BMAD alone is genuinely unestablished: a plugin marketplace exists for
        // it, but no `/plugin install` line is published under any name.
        guard case .unestablished(let bmadReason) = MethodCatalog.bmad.plugin else {
            Issue.record("bmad.plugin is \(MethodCatalog.bmad.plugin), not .unestablished")
            return
        }
        #expect(!bmadReason.trimmed().isEmpty)
    }

    /// The direct replacement A2 asks for: whatever is `.unestablished` in the
    /// catalogue must say *why*, so Preflight's warning (Task 6) has a sentence
    /// to show rather than a bare "unknown".
    @Test("Every .unestablished plugin in the catalogue names a reason")
    func unestablishedPluginsNameAReason() {
        var sawOne = false
        for pack in MethodCatalog.builtIn {
            guard case .unestablished(let reason) = pack.plugin else { continue }
            sawOne = true
            #expect(!reason.trimmed().isEmpty, "\(pack.id) names no reason for its unestablished plugin")
        }
        #expect(sawOne, "no pack is .unestablished — this test would pass vacuously otherwise")
    }

    /// Task 1's review, Minor finding 1: `codableRoundTrip` in `MethodPackTests`
    /// only ever built `plugin: .none`, so `.required` and `.unestablished` had
    /// no round-trip coverage. The catalogue now has real instances of both.
    @Test("A pack carrying .required or .unestablished round-trips through Codable")
    func pluginRequirementRoundTrips() throws {
        for pack in [MethodCatalog.aiMigrationKit, MethodCatalog.gsd, MethodCatalog.bmad] {
            let data = try JSONEncoder().encode(pack)
            let decoded = try JSONDecoder().decode(MethodPack.self, from: data)
            #expect(decoded == pack, "\(pack.id) did not round-trip")
            #expect(decoded.plugin == pack.plugin, "\(pack.id)'s plugin did not round-trip")
        }
    }
}
