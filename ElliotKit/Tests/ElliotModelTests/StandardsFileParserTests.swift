import Foundation
import Testing

@testable import ElliotModel

private let now = Date(timeIntervalSince1970: 1_754_524_800)  // 2026-08-07

@Suite("The exemptions file is read strictly")
struct StandardsFileParserTests {

    private let valid = """
        # Read by Elliot's standards sweep.
        version: 1
        repo: phmatray/AtypWebsite

        exemptions:
          - standard: ciJudgeable
            reason: >
              The only workflow is a Nuke deployment that publishes the public
              site image on push to dev.
            granted_by: philippe
            granted_at: 2026-08-07
            evidence: https://github.com/phmatray/AtypWebsite/issues/61
        """

    @Test("A well-formed file parses")
    func parsesValid() throws {
        let file = try StandardsFileParser.parse(valid, expecting: "phmatray/AtypWebsite").get()
        #expect(file.version == 1)
        #expect(file.exemptions.count == 1)
        #expect(file.exemptions[0].standard == .ciJudgeable)
        #expect(file.exemptions[0].grantedBy == "philippe")
        #expect(file.exemptions[0].reason.contains("Nuke deployment"))
    }

    /// A copy-pasted file is the likeliest way an exemption lands in the wrong
    /// repository, and it would silence an axis nobody chose to silence.
    @Test("A file naming another repository is refused")
    func refusesForeignRepo() {
        guard case .failure(.exemptionsMalformed(_, let detail)) =
            StandardsFileParser.parse(valid, expecting: "phmatray/Elliot") else {
            Issue.record("expected a refusal"); return
        }
        #expect(detail.contains("AtypWebsite"))
    }

    @Test("An unknown version is refused, not parsed on a best effort")
    func refusesUnknownVersion() {
        let text = "version: 2\nexemptions: []\n"
        guard case .failure(.exemptionsMalformed) = StandardsFileParser.parse(text, expecting: nil)
        else { Issue.record("expected a refusal"); return }
    }

    @Test("An unknown standard is refused rather than skipped")
    func refusesUnknownStandard() {
        let text = """
            version: 1
            exemptions:
              - standard: quantumReadiness
                reason: because
                granted_by: philippe
                granted_at: 2026-08-07
            """
        guard case .failure(.exemptionsMalformed(let line, _)) =
            StandardsFileParser.parse(text, expecting: nil) else {
            Issue.record("expected a refusal"); return
        }
        #expect(line == 3)
    }

    @Test("An exemption with no reason is refused")
    func refusesBlankReason() {
        let text = """
            version: 1
            exemptions:
              - standard: topics
                reason: "   "
                granted_by: philippe
                granted_at: 2026-08-07
            """
        guard case .failure(.exemptionsMalformed) = StandardsFileParser.parse(text, expecting: nil)
        else { Issue.record("expected a refusal"); return }
    }

    @Test("An empty file is a file with no exemptions")
    func emptyIsValid() throws {
        let file = try StandardsFileParser.parse("version: 1\nexemptions: []\n", expecting: nil).get()
        #expect(file.exemptions.isEmpty)
    }

    @Test("An exemption without an expiry is permanent")
    func permanentExemption() throws {
        let file = try StandardsFileParser.parse(valid, expecting: nil).get()
        #expect(file.exemptions[0].isActive(at: now.addingTimeInterval(10 * 365 * 86_400)))
    }

    /// What makes an exemption a decision rather than a permanent hole.
    @Test("An expired exemption is no longer active")
    func expiredExemption() {
        let e = Exemption(
            standard: .topics, reason: "revisit after the merge", grantedBy: "philippe",
            grantedAt: now, expires: now.addingTimeInterval(86_400), evidence: nil)
        #expect(e.isActive(at: now))
        #expect(!e.isActive(at: now.addingTimeInterval(2 * 86_400)))
    }

    /// A duplicated `repo:` defeats `refusesForeignRepo` one line lower: a
    /// reviewer reads the first line, and a lenient parser would obey the
    /// second. Strict for every top-level key, the same as inside one item.
    @Test("A duplicated top-level key is refused, not resolved by taking the last one")
    func refusesDuplicateTopLevelKey() {
        let text = """
            version: 1
            repo: phmatray/AtypWebsite
            repo: phmatray/Elliot
            exemptions: []
            """
        guard case .failure(.exemptionsMalformed(let line, let detail)) =
            StandardsFileParser.parse(text, expecting: nil) else {
            Issue.record("expected a refusal"); return
        }
        #expect(line == 3)
        #expect(detail.contains("repo"))
    }

    /// `#` inside a URL is not a comment. Losing the fragment would quietly
    /// change what an exemption cites, and the reason is the whole point of the
    /// exemption.
    @Test("A hash inside a URL survives comment stripping")
    func hashInsideURLSurvives() throws {
        let text = """
            version: 1
            exemptions:
              - standard: topics
                reason: tracked in the linked comment   # this one IS a comment
                granted_by: philippe
                granted_at: 2026-08-07
                evidence: https://github.com/phmatray/AtypWebsite/issues/61#issuecomment-42
            """
        let file = try StandardsFileParser.parse(text, expecting: nil).get()
        #expect(
            file.exemptions[0].evidence
                == "https://github.com/phmatray/AtypWebsite/issues/61#issuecomment-42")
        #expect(file.exemptions[0].reason == "tracked in the linked comment")
    }
}
