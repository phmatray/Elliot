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

    /// Whose opinion a check applied.
    ///
    /// A closed pair rather than a `Bool`, because the two are not "on and off"
    /// — they are two different *sentences*, and the check must say which one it
    /// spoke. `.elliotFloor` is Elliot asserting a taxonomy on a repository that
    /// has never been asked; `.repository` is the repository's own answer.
    public enum Source: String, Codable, Sendable, Hashable {
        /// Nobody has chosen, so ``LabelPolicy/default`` applied.
        case elliotFloor
        /// This repository declared its own set — possibly an empty one.
        case repository
    }

    /// The policy in force for one repository, **and whose it is**.
    ///
    /// The two travel together for the reason `SpendFigure` pairs a figure with
    /// whether it is complete: a caller handed a bare `[RequiredLabel]` cannot
    /// tell a taxonomy somebody chose from a floor nobody has disagreed with,
    /// and #200 is precisely the bug where a `.pass` against the second read as
    /// endorsement of the first.
    public struct Resolved: Sendable, Hashable {
        public let required: [RequiredLabel]
        public let source: Source

        public init(required: [RequiredLabel], source: Source) {
            self.required = required
            self.source = source
        }

        /// Whether anyone has answered *"what should this repository require?"*
        ///
        /// ⛔ **Not `required.isEmpty`.** A repository that declared an empty set
        /// has decided — it means *check nothing* — and asking it again would be
        /// nagging it for an answer it already gave. `nil` and `[]` are
        /// different facts, which is the same three-valued distinction
        /// ``RepositoryLabels`` is built on one type over.
        public var isUndecided: Bool { source == .elliotFloor }

        /// How the check names the set it applied.
        ///
        /// Criterion 5 of #200: a `.pass` must not read as endorsement of a
        /// taxonomy nobody chose.
        public var whose: String {
            switch source {
            case .elliotFloor: "Elliot's skills apply"
            case .repository: "this repository requires"
            }
        }
    }

    /// The policy in force for `repo`.
    ///
    /// `Repo.labelPolicy` is `nil` on every repository until someone answers, so
    /// this is the single place the fall-back happens — one property rather than
    /// a `?? LabelPolicy.default` at each call site, for the reason
    /// `Repo.preflightVerdict` is one property rather than four coalescings.
    public static func resolved(for repo: Repo) -> Resolved {
        guard let declared = repo.labelPolicy else {
            return Resolved(required: LabelPolicy.default, source: .elliotFloor)
        }
        return Resolved(required: declared, source: .repository)
    }

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
    /// `gh` was asked and did not answer. **Not** the same as an empty
    /// repository.
    case unavailable
    /// Nobody has asked yet — the request is in flight, or the editor has not
    /// opened, or there is no `gh` to run.
    ///
    /// The **third** silence, and it was folded into `.unavailable` until code
    /// review caught it on this type's own branch. That cost a sentence which
    /// asserts a call that never happened — *"gh did not answer for this
    /// repository"* — printed for the whole duration of every healthy
    /// `gh label list`, and permanently on a board still starting up. This type
    /// exists to keep silences apart; the fix for a third one is a third case,
    /// not a reused sentence.
    case notAsked

    /// From what `gh` answered, `nil` meaning it was asked and did not answer.
    ///
    /// ⚠️ `nil` here is specifically the `try?` of a call that **ran**. Never
    /// construct this for a call nobody made — that is `.notAsked`, and the
    /// difference is a claim about `gh` that would not be true.
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
        case .unavailable, .notAsked: []
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
        case .unavailable, .notAsked:
            return false
        }
    }

    /// The sentence the editor prints under an empty picker, or `nil` when
    /// there is a list to show instead.
    ///
    /// **Three silences, three sentences, and never one borrowed for another.**
    /// The repository has nothing; `gh` was asked and did not answer; nobody has
    /// asked yet. Only the middle one is a finding about `gh`, and saying it for
    /// the other two would be a confident wrong answer — which this codebase
    /// treats as worse than an error, and which the two-case version of this
    /// property printed for the entire duration of every successful lookup.
    public var explanation: String? {
        switch self {
        case .known(let names):
            names.isEmpty ? "This repository has no labels yet." : nil
        case .unavailable:
            "Could not be established: gh did not answer for this repository."
        case .notAsked:
            "Reading this repository's labels…"
        }
    }
}
