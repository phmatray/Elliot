import Testing

@testable import ElliotModel

/// `isReadOnly` decides the scheduling lane and whether the working-tree
/// sentinel is armed, and one of its five readers in `RunScheduler` is a
/// **negation** the compiler cannot check. So every case is named here, and the
/// two sets are required to partition `allCases`: a sixth kind that nobody
/// classifies fails this suite instead of silently joining the writers.
@Suite("Skill kinds — which ones only read")
struct SkillKindReadOnlyTests {

    @Test("The three plugin skills write")
    func writersWrite() {
        #expect(SkillKind.createIssue.isReadOnly == false)
        #expect(SkillKind.implementIssue.isReadOnly == false)
        #expect(SkillKind.mergePR.isReadOnly == false)
    }

    @Test("An analysis and an appraisal only read")
    func readersRead() {
        #expect(SkillKind.analyzeRepo.isReadOnly)
        #expect(SkillKind.appraiseCards.isReadOnly)
    }

    @Test("Every kind is classified, and the two sets cover allCases")
    func theSetsPartitionAllCases() {
        let readers = SkillKind.allCases.filter(\.isReadOnly)
        let writers = SkillKind.allCases.filter { !$0.isReadOnly }
        #expect(readers.count + writers.count == SkillKind.allCases.count)
        #expect(Set(readers) == [.analyzeRepo, .appraiseCards])
        #expect(Set(writers) == [.createIssue, .implementIssue, .mergePR])
    }

    /// The claim this made through `slashName == nil` until #363 deleted that
    /// property for hardcoding `/ai-migration-kit:…`, where a `MethodPack` now
    /// decides per repository. The claim outlived its expression; only the
    /// expression is new.
    ///
    /// Under packs it is two facts, and the compiler proves one of them: a
    /// prompt is built by `SlashCommandBuilder.prompt(for:method:strategy:)`,
    /// which takes a **`TriggerAction`** — three cases, none of them an
    /// appraisal — so this kind cannot reach the builder, nor its
    /// `undeclaredStep` fallback, at all. An appraisal's prompt comes from
    /// `AppraisalPromptBuilder`, the way an analysis's comes from
    /// `AnalysisPromptBuilder`.
    ///
    /// What the compiler does **not** prove is the other fact, so it is
    /// asserted: no pack declares a step for this kind, the way
    /// `MethodCatalog.aiMigrationKit` says `.analyzeRepo` is "deliberately
    /// absent here and everywhere". ⛔ Not already covered by
    /// `MethodCatalogTests.everyKindIsAnswered`: that compares each pack against
    /// a table which merely *omits* this kind, so a pack and the table gaining
    /// a step together leaves it green while this claim dies. A claim asserted
    /// only by two files' silence is a claim nothing can keep honest.
    @Test("An appraisal is Elliot's own prompt: no method declares a step for it")
    func appraisalIsElliotsOwnPrompt() {
        #expect(SkillKind.appraiseCards.skillName == "appraise-cards")
        for pack in MethodCatalog.builtIn {
            #expect(
                pack.steps[.appraiseCards] == nil,
                "\(pack.id) declares a step for an appraisal, which is Elliot's own prompt"
            )
        }
    }

    @Test("The raw value is what lands in skillRun.kind, and it is stable")
    func rawValueIsPersisted() {
        // Named here because it is a **storage** decision: this string is
        // written into every appraisal run's row, and changing it later would
        // orphan them all with no migration to notice.
        #expect(SkillKind.appraiseCards.rawValue == "appraiseCards")
        #expect(SkillKind(rawValue: "appraiseCards") == .appraiseCards)
    }
}
