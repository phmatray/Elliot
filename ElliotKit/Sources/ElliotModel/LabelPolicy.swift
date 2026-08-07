import Foundation

/// One label Elliot's skills expect a repository to have.
///
/// Colour and description travel with the name because the point of knowing a
/// label is missing is being able to create it, and `gh label create` wants all
/// three. A name alone would make the fix a second decision.
public struct RequiredLabel: Codable, Sendable, Hashable {
    public var name: String
    /// Six hex digits, no leading `#` — the shape `gh label create --color`
    /// takes. A `#` is rejected, which is why `LabelPolicyTests` pins the form
    /// rather than trusting each entry to be typed correctly.
    public var color: String
    public var description: String

    public init(name: String, color: String, description: String) {
        self.name = name
        self.color = color
        self.description = description
    }
}

/// The labels Elliot requires, and what a repository is missing from them.
///
/// **Elliot's own data, deliberately, rather than the target repository's
/// profile.** The taxonomy in `.claude/skills/repo-profile.md` is what the
/// *skills* read, and it is prose — narrative bullets with TODO comments inside
/// them, mixing labels that exist with labels that ought to:
///
/// ```markdown
/// - **Priority tiers:** <!-- TODO: none exist. … Either create one (`gh label create "priority: high" …`) -->
/// ```
///
/// A parser over that would lift `priority: high` out of a comment explaining
/// that no such label exists — a confident wrong answer, which this codebase
/// treats as worse than an error. So this is a *floor Elliot asserts*, and the
/// check that reads it says whose opinion it is.
///
/// Pure: no `gh`, no clock, no file system. `PreflightService` supplies the
/// repository's real labels and this decides what is absent.
public enum LabelPolicy {
    /// GitHub's own four stock type labels, with GitHub's own colours.
    ///
    /// A floor that is already true on a freshly created repository, so the
    /// check ships green where it is already satisfied. That is on purpose: the
    /// mechanism is what #170 is about, and an argument over *which* labels to
    /// require should not be the thing that blocks Elliot ever checking at all.
    public static let `default` = [
        RequiredLabel(name: "bug", color: "d73a4a", description: "Something isn't working"),
        RequiredLabel(
            name: "enhancement", color: "a2eeef", description: "New feature or request"
        ),
        RequiredLabel(
            name: "documentation", color: "0075ca",
            description: "Improvements or additions to documentation"
        ),
        RequiredLabel(
            name: "question", color: "d876e3", description: "Further information is requested"
        ),
    ]

    /// Which of `required` the repository does not have, in the policy's order.
    ///
    /// Case-insensitive, because GitHub is: it refuses a second casing of a
    /// label that exists, so treating `Bug` as absent would both misreport a
    /// label that is right there and make the fix fail on every repository that
    /// already had one.
    ///
    /// The order is the policy's rather than the repository's, so two readings
    /// of an unchanged repository list the same names in the same sequence — a
    /// reshuffle in a row a human is watching reads as a change.
    public static func missing(
        required: [RequiredLabel], present: [String]
    ) -> [RequiredLabel] {
        let have = Set(present.map { $0.lowercased() })
        return required.filter { !have.contains($0.name.lowercased()) }
    }
}
