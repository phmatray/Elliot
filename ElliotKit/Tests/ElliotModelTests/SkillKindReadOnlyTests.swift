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

    @Test("An appraisal is Elliot's own prompt, not a plugin skill")
    func appraisalHasNoSlashCommand() {
        #expect(SkillKind.appraiseCards.skillName == "appraise-cards")
        #expect(SkillKind.appraiseCards.slashName == nil)
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
