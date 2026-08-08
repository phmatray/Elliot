import Foundation
import Testing

@testable import ElliotModel

@Suite("Which axes apply to a repository")
struct StandardApplicabilityTests {

    private func summary(
        _ name: String = "phmatray/Foo", lang: String? = "C#",
        fork: Bool = false, archived: Bool = false, empty: Bool = false,
        branch: String? = "main"
    ) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: name, visibility: "PUBLIC",
            defaultBranchRef: branch.map { GHRepoInfo.BranchRef(name: $0) },
            isFork: fork, isArchived: archived,
            primaryLanguage: lang.map { GHLanguage(name: $0) }, isEmpty: empty)
    }

    @Test("Every axis applies to an ordinary code repository")
    func ordinaryCodeRepo() {
        for s in Standard.allCases {
            #expect(s.applicability(to: summary()) == .applies, "\(s)")
        }
    }

    /// Forks are out of harmonisation scope, measured by `isFork` and never case
    /// by case. Today `add_editorconfig.py --commit` without `--only` would
    /// write into ten repositories and all ten are forks, because the Python
    /// requests `isFork` and never reads it.
    @Test("No axis applies to a fork")
    func forkIsOutOfScope() {
        for s in Standard.allCases {
            #expect(s.applicability(to: summary(fork: true)) == .notApplicable(.fork), "\(s)")
        }
    }

    @Test("A repository with no default branch cannot be measured")
    func noDefaultBranch() {
        #expect(Standard.topics.applicability(to: summary(branch: nil))
                == .notApplicable(.noDefaultBranch))
    }

    /// Topics and licence are about the repository as an artefact, so they apply
    /// to the seven LaTeX papers; the three code axes do not.
    @Test("A LaTeX paper is measured for topics and licence only")
    func latexPaper() {
        let paper = summary("phmatray/fire-book", lang: "TeX")
        #expect(Standard.editorconfig.applicability(to: paper) == .notApplicable(.notCode))
        #expect(Standard.dependencyAutomation.applicability(to: paper) == .notApplicable(.notCode))
        #expect(Standard.ciJudgeable.applicability(to: paper) == .notApplicable(.notCode))
        #expect(Standard.topics.applicability(to: paper) == .applies)
        #expect(Standard.licence.applicability(to: paper) == .applies)
    }

    @Test("The account's .github repository is infrastructure, not a project")
    func metaRepository() {
        #expect(Standard.licence.applicability(to: summary("phmatray/.github", lang: nil))
                == .notApplicable(.metaRepository))
    }

    /// A repository the Python README sweeps skip is not thereby a
    /// non-project. `phmatray/AAA` is an active .NET library, and its name was
    /// carried into this list by inheritance rather than by judgement.
    @Test("A real library is not a meta-repository")
    func libraryIsNotMeta() {
        for s in Standard.allCases {
            #expect(s.applicability(to: summary("phmatray/AAA")) == .applies, "\(s)")
        }
    }

    /// Every rubric must say what it leaves alone as well as what it checks —
    /// without the second half five axes drift into "the repo looks tidy" and
    /// report the same list. `benefit` is the short "why", checked separately
    /// so a sixth axis cannot ship with a rubric and no reason: a `benefit`
    /// built from the rubric is exactly the bug this test would otherwise miss
    /// (a non-empty string that says nothing on its own).
    @Test("Every axis has a title, a rubric and a benefit")
    func everyAxisIsDescribed() {
        for s in Standard.allCases {
            #expect(!s.title.isEmpty, "\(s)")
            #expect(s.rubric.count > 80, "\(s) rubric is too thin to judge against")
            #expect(!s.benefit.trimmed().isEmpty, "\(s) has no benefit")
            #expect(s.benefit.count < 200, "\(s) benefit reads like a rubric, not a clause")
        }
    }
}
