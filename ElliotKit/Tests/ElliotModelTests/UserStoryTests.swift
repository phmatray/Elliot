import Foundation
import Testing

@testable import ElliotModel

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("User story")
struct UserStoryTests {

    @Test("A story reads as one sentence")
    func narrative() {
        let story = UserStory(
            role: "developer",
            want: "to see the run log inside the card",
            benefit: "I can diagnose a failure without opening a terminal"
        )
        #expect(story.narrative == "As a developer, I want to see the run log inside the card, "
            + "so that I can diagnose a failure without opening a terminal.")
    }

    @Test("A benefit that already ends in a period is not double-punctuated")
    func narrativeDoesNotDoublePunctuate() {
        let story = UserStory(role: "user", want: "X", benefit: "Y.")
        #expect(story.narrative == "As a user, I want X, so that Y.")
    }

    @Test("Acceptance criteria are numbered after the narrative")
    func issueBodyNumbersCriteria() {
        let story = UserStory(
            role: "maintainer",
            want: "a preflight screen",
            benefit: "I know why a repo is disabled",
            acceptanceCriteria: ["every check shows its command", "  ", "a failing check offers a fix"]
        )
        #expect(story.issueBody == "As a maintainer, I want a preflight screen, so that I know why "
            + "a repo is disabled. Acceptance criteria: 1) every check shows its command "
            + "2) a failing check offers a fix")
    }

    @Test("With no criteria the body is just the narrative")
    func issueBodyWithoutCriteria() {
        let story = UserStory(role: "user", want: "X", benefit: "Y")
        #expect(story.issueBody == story.narrative)
    }

    @Test("Completeness needs all three parts", arguments: [
        (role: "a", want: "b", benefit: "c", complete: true),
        (role: "", want: "b", benefit: "c", complete: false),
        (role: "a", want: "  ", benefit: "c", complete: false),
        (role: "a", want: "b", benefit: "\n", complete: false),
    ])
    func completeness(sample: (role: String, want: String, benefit: String, complete: Bool)) {
        let story = UserStory(role: sample.role, want: sample.want, benefit: sample.benefit)
        #expect(story.isComplete == sample.complete)
    }

    @Test("The short title comes from the want clause, capitalised")
    func shortTitle() {
        let story = UserStory(role: "dev", want: "see the run log", benefit: "diagnose faster")
        #expect(story.shortTitle == "See the run log")
    }

    @Test("The short title falls back when the want clause is blank")
    func shortTitleFallsBack() {
        #expect(UserStory(role: "dev", want: "", benefit: "ship faster").shortTitle == "Ship faster")
        #expect(UserStory(role: "dev", want: "", benefit: "").shortTitle == "dev")
    }

    @Test("A card prefers its story over its label when filing")
    func cardIdeaPrefersStory() {
        var card = Card(
            repoID: UUID(), title: "Run log", body: "some stale note",
            columnEnteredAt: fixedDate, createdAt: fixedDate, updatedAt: fixedDate
        )
        card.story = UserStory(role: "dev", want: "the log", benefit: "faster diagnosis")
        #expect(card.ideaText == "As a dev, I want the log, so that faster diagnosis.")
        #expect(card.displayTitle == "Run log")
    }

    @Test("A card with no story falls back to title and body")
    func cardIdeaFallsBack() {
        let card = Card(
            repoID: UUID(), title: "Add CSV export", body: "Comma separated, UTF-8.",
            columnEnteredAt: fixedDate, createdAt: fixedDate, updatedAt: fixedDate
        )
        #expect(card.ideaText == "Add CSV export. Comma separated, UTF-8.")
    }

    @Test("An incomplete story is reported as such rather than silently used")
    func incompleteStoryIsFlagged() {
        var card = Card(
            repoID: UUID(), title: "Run log",
            columnEnteredAt: fixedDate, createdAt: fixedDate, updatedAt: fixedDate
        )
        #expect(!card.hasIncompleteStory)
        card.story = UserStory(role: "dev", want: "the log", benefit: "")
        #expect(card.hasIncompleteStory)
    }

    @Test("A story survives a round trip through JSON")
    func codableRoundTrip() throws {
        let story = UserStory(
            role: "dev", want: "the log", benefit: "faster diagnosis",
            acceptanceCriteria: ["streams live"]
        )
        let data = try JSONEncoder().encode(story)
        #expect(try JSONDecoder().decode(UserStory.self, from: data) == story)
    }
}
