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

/// What the card editor knows about the labels a repository actually has.
///
/// Two cases, and keeping them apart is the whole reason this is a type rather
/// than a `[String]`. `.known([])` is a **finding** — this repository has no
/// labels, so every label a card asks for is one it does not have. `.unavailable`
/// is the *absence of a finding*: `gh` was not reachable, or is not
/// authenticated, and nothing has been established about anything.
///
/// Collapsing them is a defect this codebase has already priced twice — in
/// `GHClient.labels`, which throws rather than answering `[]` for the same
/// reason, and in `PreflightService.labelsCheck`, whose comment states the duty
/// plainly: *a failure to ask is not a finding about the answer*. Here the cost
/// would be a card painted red on a laptop that is merely offline, and a picker
/// silently claiming a repository has no labels on no evidence at all.
///
/// Pure, so `ElliotAppKit`'s job is one call and one mapping rather than a rule.
public enum RepositoryLabels: Sendable, Hashable {
    /// `gh` answered, and this is what it said.
    case known([String])
    /// `gh` did not answer. **Not** the same as an empty repository.
    case unavailable

    /// From what `gh` answered, `nil` meaning it did not answer at all — the
    /// shape `try? await gh.labels(repo:)` produces.
    public init(ghAnswer: [String]?) {
        self = ghAnswer.map(RepositoryLabels.known) ?? .unavailable
    }

    /// Whether anything at all has been established. The editor needs this to
    /// explain *which* silence the reader is looking at.
    public var isKnown: Bool {
        if case .known = self { return true }
        return false
    }

    /// The labels the picker may offer, in the repository's own order.
    ///
    /// Empty under `.unavailable` — offering a remembered list would let a card
    /// ask for a label nobody has confirmed still exists, which is the failure
    /// mode approach A was rejected for.
    public var offerable: [String] {
        switch self {
        case .known(let names): names
        case .unavailable: []
        }
    }

    /// Whether this repository is **known not to have** `name`.
    ///
    /// Case-insensitive, for `LabelPolicy.missing`'s reason: GitHub refuses a
    /// second casing of a label that exists, so `Bug` and `bug` are one label
    /// and reporting either as absent would misname a label that is right there.
    ///
    /// Always `false` under `.unavailable`. Accusation requires evidence.
    public func isMissing(_ name: String) -> Bool {
        switch self {
        case .known(let names):
            let have = Set(names.map { $0.lowercased() })
            return !have.contains(name.trimmed().lowercased())
        case .unavailable:
            return false
        }
    }

    /// The sentence the editor prints under an empty picker, or `nil` when
    /// there is a list to show instead.
    ///
    /// Two silences, two sentences, and never the same one: one says the
    /// repository has nothing, the other says nobody could find out.
    public var explanation: String? {
        switch self {
        case .known(let names):
            names.isEmpty ? "This repository has no labels yet." : nil
        case .unavailable:
            "Could not be established: gh did not answer for this repository."
        }
    }
}
