import Foundation

/// Why a repository's row is not simply fine.
///
/// Two families live here. The first six are what `RepoReconciler` decides from
/// GitHub, the disk and the store. The rest are what a probe *observes* by
/// asking git, and nothing about how rows are built changes to accommodate them.
///
/// ⚠️ This said the probe's verdicts "refine a row the reconciler already called
/// `.ok`" until #189, and that sentence was quoted in the issue as the line to
/// move: a probe now refines any row `isProbeable` admits, which is `.ok` **and**
/// `.notChecked`. The two are composed by `refined(by:)` rather than one
/// replacing the other, because a clone's git state and its owner's listing
/// answer different questions and an outage only takes the second away.
public enum RepoIssue: Sendable, Hashable {
    case ok
    case notCloned
    case notRegistered
    case missing
    case misplaced(expected: String)

    /// On disk, registered, and absent from GitHub's answer.
    ///
    /// Its own case rather than `.ok` with a telling detail, because `.ok` is
    /// the verdict nobody scrolls to read and this row has at least three
    /// causes, none of them "fine": the repository was renamed or transferred,
    /// so the local remote is stale; it was deleted, so this clone is the only
    /// copy; or the listing itself was incomplete — pagination, a rate limit, a
    /// scope the token lacks.
    ///
    /// The third is what settles it. An incomplete answer is not a fact about
    /// the repository at all, and it would mark *many* rows at once. A row that
    /// says "fine" when the real answer is "I could not check" is a
    /// non-measurement rendered as a pass, which is the one thing this codebase
    /// spends its effort refusing to do.
    ///
    /// What it deliberately does **not** claim is *which* of the three happened.
    /// Telling "GitHub said no" from "GitHub did not answer" needs the scanner to
    /// report its own failure modes upward; the reconciler is pure and cannot
    /// ask. That is a separate change — made in #148, which is `.notChecked`
    /// below. `.unlisted` keeps its exact meaning: GitHub answered, and this
    /// repository was not in the answer.
    case unlisted

    /// On disk, and GitHub was never successfully asked about it.
    ///
    /// The other half of `.unlisted`, and the change that comment defers.
    /// `.unlisted` is a fact about the repository — GitHub answered, and this
    /// was not in the answer. This is a fact about the *listing*: no answer
    /// arrived, so nothing is known about the repository at all.
    ///
    /// It carries no fix, deliberately. Every action the page could offer here
    /// is grounded in the listing that failed — `Register` most of all, since
    /// `RepoRegistryService.register` asks `gh repo view` for the default branch
    /// and falls back to `"main"` when *that* fails too. Offering it during an
    /// outage bakes a guess into the store, for the same reason the row appeared.
    ///
    /// Since #189 a probe may *replace* this verdict with what git saw on the
    /// clone, and a row that comes back `.behind` does then get `.pull`. That is
    /// not a hole in the paragraph above: by then the row is no longer
    /// `.notChecked`, and a `--ff-only` against an already-configured upstream
    /// is git alone — it never asks the `gh` that failed. This verdict itself
    /// still carries no fix, and `Register` is still unreachable from it.
    case notChecked
    case outOfScope(OutOfScope)

    // Git state. Only a probe produces these.
    case behind(by: Int)
    case dirty
    case ahead
    case diverged
    case detached
    case noRemote
    case unreadable(String)

    public enum OutOfScope: Sendable, Hashable {
        case fork, archived, empty, otherRoot

        /// The one place fork / archived / empty is decided, for every consumer.
        ///
        /// Order is the rule, not an implementation detail: a fork reports as a
        /// fork whatever else is true, because that is the answer that decides
        /// whether anything may be written into it.
        ///
        /// `otherRoot` is deliberately absent here — it is a fact about the local
        /// tree layout, not about the repository, and only the reconciler knows it.
        public static func of(_ repo: GHRepoSummary) -> OutOfScope? {
            if repo.isFork { return .fork }
            if repo.isArchived { return .archived }
            if repo.isEmpty { return .empty }
            return nil
        }
    }

    /// The one verdict a sweep acts on.
    ///
    /// Here rather than spelled out at each of its three call sites — the fix a
    /// probe offers, the rows `syncAll` selects, and the count that enables the
    /// button. Three copies of "what counts as behind" is three chances for the
    /// button to promise something the sweep will not do.
    public var isBehind: Bool {
        if case .behind = self { return true }
        return false
    }

    /// Has a clone on disk that `git` may be asked about.
    ///
    /// Here rather than as a `==` chain inside `RepoRegistryService.refine`, for
    /// the reason `isBehind` is here: the guard was `row.issue == .ok`, #189
    /// makes it two verdicts, and the next case added to this enum has to face
    /// the question rather than inherit an answer from a `||` someone forgot to
    /// extend. Three copies of "which rows have a clone" is three chances to
    /// forget one — and the failure is silent both ways, since probing a row
    /// with no clone runs `git` against an absent path and *not* probing one
    /// that has a clone throws away a measurement that was free.
    ///
    /// `.notRegistered` and `.unlisted` have a clone too, and are deliberately
    /// out. Both are verdicts GitHub *answered*, so there is nothing a git
    /// observation could recover — and `.notRegistered` carries `Register`,
    /// which `refine`'s `fixes` assignment would take away.
    ///
    /// The `switch` is exhaustive with **no `default:`**, for the reason
    /// `showsBoardFigures` and `RepositoriesView.icon` are.
    public var isProbeable: Bool {
        switch self {
        case .ok, .notChecked:
            return true
        case .notCloned, .notRegistered, .missing, .misplaced, .unlisted, .outOfScope,
            .behind, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable:
            return false
        }
    }

    /// What a git observation does to this verdict. Pure, total, and the whole
    /// of the decision — there is no second copy of it at a renderer.
    ///
    /// The two arguments answer *different questions*, which is why one has to
    /// be composed with the other rather than chosen between: `self` is what the
    /// listing established (or failed to establish), `observed` is what `git`
    /// saw on the disk. A row that is not probeable never asked git anything, so
    /// it keeps what it had and `observed` is discarded.
    ///
    /// ⛔ **`.notChecked` refined by `.ok` stays `.notChecked`, and that arm is
    /// the reason this function exists.** A clean, attached, up-to-date clone
    /// whose owner was never listed is *still* not checked: "clean and up to
    /// date" is a claim about a clone, and the row's open question is about the
    /// repository. Collapsing the pair to `.ok` would render a non-measurement
    /// as a pass — the exact defect #148 removed one layer up, restored here by
    /// a single `return observed`.
    ///
    /// Every *other* observation wins: dirty, detached, diverged, ahead, no
    /// remote, behind and `.outOfScope(.otherRoot)` are each a fact `git`
    /// established on the local disk, which is precisely what an outage does not
    /// take away.
    ///
    /// ⚠️ **`.unreadable("fetch failed")` is the one that does not fit that
    /// sentence, and it is the likely one.** `fetch` is a network call, so a
    /// modal outage — no network at all — fails the listing *and* the fetch, and
    /// every row renders `unreadable` rather than `not checked`. #189's spec
    /// decided that deliberately ("more informative than `.notChecked` … it is
    /// an observation, not a guess") and this implements that decision; but the
    /// argument for it is weaker than for the other six, because what was
    /// observed is one global failure restated per clone. Pinned by
    /// `notCheckedOverAnUnreachableRemoteIsUnreadable`, so a later reversal is a
    /// decision rather than a drift.
    ///
    /// Written as an exhaustive `switch` over `self` rather than as two `==`
    /// guards, and that is the same argument `isProbeable` makes one property
    /// up: with guards, a verdict added to `isProbeable`'s `true` arm compiles
    /// here untouched and silently inherits `.ok`'s "take whatever git saw",
    /// which is the inheritance both of these exist to stop. Two exhaustive
    /// switches mean a new case must answer *both* questions to build.
    public func refined(by observed: RepoIssue) -> RepoIssue {
        switch self {
        case .ok:
            return observed
        case .notChecked:
            return observed == .ok ? .notChecked : observed
        // Not probeable: git was never asked, so there is no observation to
        // weigh. Listed rather than swept into a `default:`, for the reason
        // above — and these are exactly `isProbeable`'s `false` arm.
        case .notCloned, .notRegistered, .missing, .misplaced, .unlisted, .outOfScope,
            .behind, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable:
            return self
        }
    }
}

/// The one thing a row's button does. Nothing here deletes.
public enum RepoFix: Sendable, Hashable {
    case clone(nameWithOwner: String, into: String)
    case move(from: String, to: String)
    case register(path: String)
    case forget(repoID: UUID)
    /// Fast-forward, or refuse. Offered only to a clone that is clean, attached
    /// and strictly behind — the one state where a pull cannot lose anything.
    case pull(path: String)

    /// The button's label. `move` names its destination, because it relocates a
    /// directory in the user's portfolio and must say so before it runs.
    public var label: String {
        switch self {
        case .clone: "Clone"
        case .move(_, let to): "Move to \((to as NSString).lastPathComponent)"
        case .register: "Register"
        case .forget: "Forget"
        case .pull: "Pull"
        }
    }
}

/// What a row can do about the **board**, as opposed to about itself.
///
/// Its own vocabulary rather than a sixth `RepoFix` case, and each mismatch is
/// load-bearing rather than a matter of taste. `RepoFix` is *"the one thing a
/// row's button does"* and every case repairs the repository's state — opening
/// a window repairs nothing. Its buttons route through
/// `AppModel.apply(_ fix:)`, which calls `RepoRegistryService` and then re-reads
/// GitHub, the disk and the store; navigation would trigger a portfolio-wide
/// sweep. They carry `.disabled(model.isReconciling)`, which is right for a
/// repair and absurd for "show me the cards". And `RepoReconciler` is pure by
/// design so that "this directory is misplaced" is provable; teaching it to
/// emit a navigation affordance would couple *what is wrong here* to *where can
/// I go from here*.
public enum RepoRowBoardAction: Sendable, Hashable {
    /// Registered — Elliot drives this checkout and the board can be scoped to it.
    case open(repoID: UUID)
    /// On disk, not registered. `RepoFix.register` is the way in; offering both
    /// would name an act that cannot work yet.
    case registerFirst
    /// Neither: not cloned, out of scope, or nothing to go to.
    case unavailable
}

public struct RepoRow: Identifiable, Sendable, Hashable {
    public var id: String
    public var nameWithOwner: String?
    public var path: String?
    public var repoID: UUID?
    public var visibility: RepoVisibility?
    public var issue: RepoIssue
    public var detail: String
    public var fixes: [RepoFix]

    /// What is on this repository's board, when it has one.
    ///
    /// Defaulted `nil` in the initialiser so `RepoReconciler` — which
    /// reconciles GitHub, the disk and the registration, and has no business
    /// knowing what is on a board — builds every row exactly as it did.
    /// `RepoBoardDigest` attaches these in a second, separate pass, the shape
    /// `RepoRegistryService.probe` already uses to refine a probeable row into a
    /// git verdict.
    public var board: RepoBoardTally?

    public init(
        id: String, nameWithOwner: String? = nil, path: String? = nil, repoID: UUID? = nil,
        visibility: RepoVisibility? = nil, issue: RepoIssue,
        detail: String = "", fixes: [RepoFix] = [], board: RepoBoardTally? = nil
    ) {
        self.id = id
        self.nameWithOwner = nameWithOwner
        self.path = path
        self.repoID = repoID
        self.visibility = visibility
        self.issue = issue
        self.detail = detail
        self.fixes = fixes
        self.board = board
    }

    /// Whether this row is one Elliot drives, and so may carry figures.
    ///
    /// **Not `repoID != nil`.** A registered fork has an id — `row(for:)` sets
    /// `repoID: repo?.id` on the out-of-scope branch below, and so does the
    /// `.unlisted`/`.notChecked` disk branch — so "has an id" and "is one
    /// Elliot drives" are different predicates, and the one a view would reach
    /// for is the wrong one. That is why this is a rule here rather than an
    /// `if let` at the point of rendering: `swift test` can see it.
    ///
    /// The `switch` is exhaustive with **no `default:`**, for the reason
    /// `RepositoriesView.icon` is: a verdict added to `RepoIssue` must fail to
    /// compile here, so someone decides whether it carries figures instead of
    /// inheriting an answer.
    public var showsBoardFigures: Bool {
        guard repoID != nil else { return false }
        switch issue {
        case .outOfScope:
            return false
        case .ok, .notCloned, .notRegistered, .missing, .misplaced, .unlisted, .notChecked,
            .behind, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable:
            return true
        }
    }

    /// Whether this row can send the reader to the board, and how.
    ///
    /// **Registration is the gate — not `issue == .ok`, and that is the
    /// decision.** A `.missing` row (registered, nothing on disk), an
    /// `.unlisted` one (registered, GitHub did not list it) and a registered
    /// `.outOfScope(.otherRoot)` one all still have cards on the board, and
    /// those are exactly the rows a person is looking at when they want to see
    /// them. Gating on `.ok` would refuse the reader at precisely the moment
    /// the question got interesting.
    ///
    /// Note it is `repoID`, deliberately, and not `showsBoardFigures` above:
    /// those two answer different questions. A registered fork is denied
    /// *figures* because harmonising it is not our business — but its cards
    /// exist, and refusing to show them would be that judgement leaking into
    /// navigation.
    ///
    /// `.registerFirst` is read from the row's own `fixes` rather than from
    /// `repoID == nil`. The two would usually agree; reading `fixes` is what
    /// makes "offers Register first" an assertion about **the button the row
    /// actually carries** instead of a second, independent guess at when one
    /// exists — a `.notChecked` row, for instance, is unregistered and
    /// deliberately carries no `Register` at all.
    public var boardAction: RepoRowBoardAction {
        if let repoID { return .open(repoID: repoID) }
        let offersRegister = fixes.contains {
            if case .register = $0 { return true } else { return false }
        }
        return offersRegister ? .registerFirst : .unavailable
    }
}

/// Turns GitHub, the disk and the store into one row per repository.
///
/// Pure by design: `ElliotApp` is an executable target with no tests, so the
/// judgement that a directory is in the wrong place — the one this feature acts
/// on by *moving* it — has to be provable here instead.
public enum RepoReconciler {
    /// `listing` rather than a bare `[GHRepoSummary]`, and with **no default**:
    /// a caller that omitted the failures would silently re-assert that GitHub
    /// answered, which is precisely the defect #148 fixed one layer up.
    public static func rows(
        listing: GitHubListing, disk: [RepoSlot],
        registered: [Repo], layout: RepoTreeLayout
    ) -> [RepoRow] {
        let github = listing.repos
        var byName: [String: RepoRow] = [:]
        let diskByName = Dictionary(disk.map { ($0.nameWithOwner, $0) }, uniquingKeysWith: { a, _ in a })
        let registeredByName = Dictionary(
            registered.map { ($0.nameWithOwner, $0) },
            uniquingKeysWith: { a, _ in a })

        for remote in github {
            byName[remote.nameWithOwner] = row(
                for: remote, disk: diskByName,
                registered: registeredByName, layout: layout)
        }

        // A clone or a registration GitHub did not mention still gets a row —
        // silence is how a repository disappears from a sweep unnoticed.
        //
        // The failed-listing branch comes first, and that ordering is the whole
        // of #148: both verdicts below read GitHub's *silence*, and silence from
        // an owner nobody could reach is not an answer. Unregistered, the verdict
        // stays `.notRegistered`: it is already actionable and already carries
        // its fix. Registered, it is `.unlisted` and not `.ok` — nothing is wrong
        // on disk, but nothing was confirmed either, and those are different
        // answers.
        for slot in disk where byName[slot.nameWithOwner] == nil {
            let path = "\(layout.root)/\(slot.owner)/\(slot.visibility.rawValue)/\(slot.name)"
            let known = registeredByName[slot.nameWithOwner]
            if let failure = listing.failure(for: slot.owner) {
                byName[slot.nameWithOwner] = RepoRow(
                    id: slot.nameWithOwner, nameWithOwner: slot.nameWithOwner, path: path,
                    repoID: known?.id, visibility: slot.visibility, issue: .notChecked,
                    detail: "On disk; the listing for \(slot.owner) failed: \(failure.reason)")
                continue
            }
            byName[slot.nameWithOwner] = RepoRow(
                id: slot.nameWithOwner, nameWithOwner: slot.nameWithOwner, path: path,
                repoID: known?.id, visibility: slot.visibility,
                issue: known == nil ? .notRegistered : .unlisted,
                detail: "On disk; GitHub did not list it.",
                fixes: known == nil ? [.register(path: path)] : [])
        }

        for repo in registered where byName[repo.nameWithOwner] == nil {
            let inTree = layout.slot(forPath: repo.path) != nil
            byName[repo.nameWithOwner] = RepoRow(
                id: repo.nameWithOwner, nameWithOwner: repo.nameWithOwner, path: repo.path,
                repoID: repo.id, issue: inTree ? .missing : .outOfScope(.otherRoot),
                detail: inTree
                    ? "Registered, but nothing is at \(repo.path)."
                    : "Registered outside \(layout.root)'s owner folders; left alone.",
                fixes: inTree ? [.forget(repoID: repo.id)] : [])
        }

        return byName.values.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    private static func row(
        for remote: GHRepoSummary, disk: [String: RepoSlot],
        registered: [String: Repo], layout: RepoTreeLayout
    ) -> RepoRow {
        let name = remote.nameWithOwner
        let repo = registered[name]
        // The disk is the authority on presence: a slot exists only where the
        // scanner saw a `.git`. A registered path with no slot is *gone*, which
        // is a different row from one that was never cloned.
        let actual = disk[name].map { "\(layout.root)/\($0.owner)/\($0.visibility.rawValue)/\($0.name)" }

        if let why = RepoIssue.OutOfScope.of(remote) {
            let detail: String =
                switch why {
                case .fork: "A fork — out of scope."
                case .archived: "Archived on GitHub — out of scope."
                case .empty: "Empty on GitHub — nothing to measure."
                case .otherRoot: "Out of scope."
                }
            return RepoRow(
                id: name, nameWithOwner: name, path: actual ?? repo?.path, repoID: repo?.id,
                visibility: remote.repoVisibility,
                issue: .outOfScope(why),
                detail: detail)
        }

        guard
            let expected = layout.expectedPath(
                nameWithOwner: name,
                visibility: remote.repoVisibility)
        else {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual ?? repo?.path, repoID: repo?.id,
                visibility: remote.repoVisibility, issue: .outOfScope(.otherRoot),
                detail: "Owner \(name.split(separator: "/").first ?? "?") is not configured.")
        }

        guard let actual else {
            // Registered but absent is `.missing`, and its fix is to forget the
            // registration — never to clone on top of a path Elliot still holds.
            if let repo, layout.slot(forPath: repo.path) != nil {
                return RepoRow(
                    id: name, nameWithOwner: name, path: repo.path, repoID: repo.id,
                    visibility: remote.repoVisibility, issue: .missing,
                    detail: "Registered, but nothing is at \(repo.path).",
                    fixes: [.forget(repoID: repo.id)])
            }
            return RepoRow(
                id: name, nameWithOwner: name, repoID: repo?.id,
                visibility: remote.repoVisibility, issue: .notCloned,
                detail: "On GitHub, no clone under \(layout.root).",
                fixes: [.clone(nameWithOwner: name, into: expected)])
        }

        if actual != expected {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual, repoID: repo?.id,
                visibility: remote.repoVisibility, issue: .misplaced(expected: expected),
                detail: "Cloned at \(actual); expected \(expected).",
                fixes: [.move(from: actual, to: expected)])
        }

        guard let repo else {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual,
                visibility: remote.repoVisibility, issue: .notRegistered,
                detail: "Cloned in the right place; Elliot does not know it yet.",
                fixes: [.register(path: actual)])
        }

        // ⛔ **Not `detail: actual`.** The path is carried by `path`, and this
        // was the one verdict of ten whose `detail` was not a sentence — so a
        // row rendered straight from the reconciler showed the same path twice,
        // in two faces (#218).
        //
        // ⚠️ It is deliberately **not** "Up to date." That is
        // `RepoRegistryService.explain`'s sentence for the *probe's* `.ok`, and
        // the two `.ok`s do not mean the same thing: the probe has fetched and
        // found the clone clean, attached and level with upstream, whereas this
        // one has only established that the repository is registered and cloned
        // where the layout says it belongs. Copying that sentence here would be
        // a claim about git made by code that never ran it.
        //
        // Fixed here rather than by having the view suppress a `detail` equal to
        // `path`: that is a reader compensating for a writer, and it leaves the
        // duplicate in the model for the next reader to meet. Same argument as
        // #191, one type over.
        return RepoRow(
            id: name, nameWithOwner: name, path: actual, repoID: repo.id,
            visibility: remote.repoVisibility, issue: .ok,
            detail: "Cloned where it belongs.")
    }
}
