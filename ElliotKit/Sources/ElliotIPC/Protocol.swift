import ElliotModel
import Foundation

/// Bumped whenever the wire format changes. A helper embedded in an old app
/// bundle meeting a newer app fails loudly on `hello` rather than misbehaving
/// halfway through a move.
///
/// **2** — runs now carry the verified outcome, the exit code and their terminal
/// flags; list answers are pages that say when they were cut; the agent can
/// update a card, cancel a run, list repositories, wait on a run and ask what to
/// do next. Version 1 shipped the agent prose where it needed facts, and a
/// silent slice where it needed a count. Neither is fixable in a compatible way,
/// so the number moves and an old helper is turned away at the handshake.
///
/// **3** — repository analysis: `analyzeRepo`, `listProposals`,
/// `acceptProposals`, `rejectProposals`. Written against 2 while 2 was still
/// unreleased, and renumbered on the way in: 2 reached `main` first, so a
/// helper claiming 2 is one that cannot analyse anything. Additive to the app,
/// but not to the helper — a 3 helper meeting a 2 app would send a request that
/// app cannot decode, which is precisely what the handshake exists to refuse.
///
/// **4** — a run says which analysis it belongs to, which angle it read
/// through, and what it harvested: `RunDTO.analysisID`, `RunDTO.angle` and
/// `RunDTO.analysisReport`. Additive as JSON, and bumped anyway, because
/// `workingTreeChanged` is tri-state: absent means the git sentinel never ran.
/// A 4 helper talking to a 3 app would find it absent on every analysis run
/// and report a repository nobody checked as unchecked-for-the-wrong-reason —
/// a statement about the user's checkout, derived from the age of their app
/// bundle. Absent has to keep meaning one thing, so the pairing is refused.
///
/// **5** — the wire carries a picture of a window: `screenshot` and
/// `ScreenshotDTO`. Purely additive to the app, and refused anyway in the one
/// direction that matters. A 5 helper sending `.screenshot` to a 4 app sends a
/// case that app has no branch for, and a request that cannot be decoded fails
/// somewhere inside the socket rather than at the handshake — which is the
/// difference between "your helper is older than your Elliot" and an agent
/// concluding the board is broken. The other direction is harmless and is
/// refused for the same reason every other pairing is: one number, one meaning.
///
/// **6** — `CardDTO` carries `prStatus`: what GitHub last said about the card's
/// pull request. Additive, and both directions degrade quietly rather than
/// dangerously — a 5 helper drops a field it has no property for, a 6 helper
/// reads `nil` from a 5 app, and `nil` already means "no reading". So this bump
/// is not protecting against a crash; it is keeping the rule that one number
/// means one wire, which is what makes the handshake worth reading at all.
///
/// **7** — `VerifiedOutcomeDTO`'s `merged` and `closed_unmerged` carry the
/// pull request they are about (`number`, `url`, `branch`), so a card that
/// reaches Done without ever having been seen as `pr_open` can still say what
/// finished it (#139). Additive on the wire, like 6, and degrading the same
/// quiet way — but a 6 helper renders a Done card's receipt with no pull
/// request at all, which is the defect this closes rather than a cosmetic loss.
///
/// **8** — `RunDTO` carries `resultSource`: whose words `resultText` is, one of
/// `agent`, `stderr` or `elliot` (#288). Additive on the wire, and refused in
/// the direction that matters for the same reason 4 was. The field is
/// tri-state by absence: **absent** means the run finished before anything
/// recorded a source, which is a real answer about history and not a synonym
/// for `agent`. An 8 helper talking to a 7 app would find it absent on *every*
/// run — including the ones that stored stderr — and would report the whole
/// board as the agent's prose, which is the defect this closes rather than a
/// cosmetic loss. One number, one wire.
///
/// ⚠️ The issue that asked for this said "bump from 6", read off a base that
/// had since reached 7. Writing 7 would have left the number unchanged while
/// the wire moved. Read this constant, never a plan.
public let elliotProtocolVersion = 8

/// The build that answered, for `hello` and for the MCP server's own version.
///
/// Deliberately not a literal. A hardcoded `"1.0.0"` in a handshake names
/// nothing, and the one moment the version matters is a bug report from the
/// field describing behaviour that no longer exists in the source.
public enum ElliotBuild {
    /// The marketing version, and the one place it is written.
    ///
    /// `Scripts/build-app.sh` reads this line to stamp
    /// `CFBundleShortVersionString`, so the bundle cannot claim a version the
    /// source does not. Bump it here, nowhere else.
    public static let marketingVersion = "0.1.0"

    /// `"0.1.0 (34)"` inside the app bundle, which both shipped binaries get:
    /// `elliot-mcp` lives in `Elliot.app/Contents/MacOS` beside the app, so
    /// `Bundle.main` finds the app's `Info.plist` for it too.
    ///
    /// `"0.1.0+dev"` from `swift build`, which produces no bundle. Marked as
    /// such rather than passed off as a release: a bug report naming `+dev` says
    /// "built from a working tree", which is exactly what it was.
    public static let version: String = {
        let info = Bundle.main.infoDictionary
        return describe(
            short: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }()

    /// Split out from the bundle lookup so it can be tested: `Bundle.main`
    /// answers differently in an app, in a bare binary and under a test runner,
    /// and a version string is exactly the sort of thing that is only ever read
    /// once something has already gone wrong.
    static func describe(short: String?, build: String?) -> String {
        switch (short, build) {
        case (let short?, let build?): "\(short) (\(build))"
        case (let short?, nil): short
        case (nil, let build?): "\(marketingVersion) (\(build))"
        case (nil, nil): "\(marketingVersion)+dev"
        }
    }
}

// MARK: - Requests

public enum ElliotRequest: Codable, Sendable, Equatable {
    case hello(protocolVersion: Int, token: String, client: String)
    case listCards(repo: String?, column: ElliotModel.Column?, limit: Int)
    case getCard(id: UUID)
    case createCard(
        repo: String,
        title: String,
        body: String,
        story: StoryInput?,
        column: ElliotModel.Column,
        idempotencyKey: String?
    )
    /// Corrects what the user wrote: label, note, story. Refused once the card
    /// carries an issue number — from then on github.com is the record.
    case updateCard(id: UUID, title: String, body: String, story: StoryInput?)
    case moveCard(id: UUID, to: ElliotModel.Column, followUps: [String])
    case listRuns(cardID: UUID?, limit: Int)
    /// Holds the connection until the run reaches a terminal state or the window
    /// closes. See `ElliotTimeouts`.
    case awaitRun(id: UUID, timeoutSeconds: Int)
    case cancelRun(id: UUID)
    case listRepos
    /// What to do next, ranked. The one request that answers a question rather
    /// than fetching a row.
    case next(repo: String?, limit: Int)
    /// Angles arrive as strings so an unknown one is a clear error message
    /// rather than a decoding failure that loses the whole request.
    case analyzeRepo(repo: String, angles: [String], maxStories: Int, instructions: String)
    case listProposals(analysisID: UUID?, repo: String?, status: String?, limit: Int)
    case acceptProposals(ids: [UUID])
    case rejectProposals(ids: [UUID])
    /// A picture of one of Elliot's own windows, so an agent can check a change
    /// that moved something on screen.
    ///
    /// A read: it changes nothing, and it deliberately does **not** launch the
    /// app. Photographing a board that was not running answers a question about
    /// a live board with a picture of a fresh one.
    ///
    /// `window` is a scene id rather than a title, because titles are localised
    /// and change with the selection; `maxInlineBytes` is a base64 budget, and
    /// non-positive means "you decide".
    case screenshot(window: String, maxInlineBytes: Int)

    /// The three parts of a user story, separately — so a skill generating
    /// stories from a repository can fill them in rather than hand over prose
    /// that would have to be parsed back apart.
    public struct StoryInput: Codable, Sendable, Hashable {
        public var role: String
        public var want: String
        public var benefit: String
        public var acceptanceCriteria: [String]

        public init(role: String, want: String, benefit: String, acceptanceCriteria: [String] = []) {
            self.role = role
            self.want = want
            self.benefit = benefit
            self.acceptanceCriteria = acceptanceCriteria
        }

        public var story: UserStory {
            UserStory(role: role, want: want, benefit: benefit, acceptanceCriteria: acceptanceCriteria)
        }
    }
}

public extension ElliotRequest {
    /// How long the socket must be willing to wait for this request.
    ///
    /// `awaitRun` is the only request that is slow on purpose, and the socket
    /// deadline has to outlive the server's own window. Get that backwards and
    /// the client hangs up on an answer that was already on its way, which the
    /// caller reads as a dead app rather than as a run still going.
    ///
    /// Derived from the request instead of passed by the caller so no call site
    /// can forget it.
    var socketTimeout: TimeInterval {
        switch self {
        case .awaitRun(_, let seconds):
            TimeInterval(ElliotTimeouts.clampAwaitSeconds(seconds)) + ElliotTimeouts.awaitGrace
        default:
            ElliotTimeouts.request
        }
    }
}

// MARK: - Errors

public enum ElliotErrorCode: String, Codable, Sendable {
    case appUnavailable = "app_unavailable"
    case protocolMismatch = "protocol_mismatch"
    case unauthorized
    case cardNotFound = "card_not_found"
    case runNotFound = "run_not_found"
    case repoNotFound = "repo_not_found"
    case moveBlocked = "move_blocked"
    /// The card is filed as a GitHub issue, so its text belongs to the issue now.
    ///
    /// Its own code rather than `readOnly`: an agent that hears "read only"
    /// retries when Elliot comes up, and this refusal is permanent. It is also
    /// the most interesting thing `updateCard` can say.
    case cardAlreadyFiled = "card_already_filed"
    /// The database was opened read-only because Elliot is not running.
    case readOnly = "read_only"
    case internalError = "internal_error"
    case analysisNotFound = "analysis_not_found"
    /// Reserved for a future single-proposal lookup request; nothing in the
    /// wire protocol throws this yet.
    case proposalNotFound = "proposal_not_found"
    case unknownAngle = "unknown_angle"
    case analysisRefused = "analysis_refused"
    /// No scene by that id exists. A typo, or a helper newer than the app.
    case windowNotFound = "window_not_found"
    /// The id is real and that window is simply not open right now.
    ///
    /// Its own code beside `windowNotFound` for the reason `cardAlreadyFiled`
    /// has its own beside `readOnly`: the two demand different next actions —
    /// fix the name, or open the window — and an agent that cannot tell them
    /// apart will retry the one that can never succeed.
    case windowNotOpen = "window_not_open"
}

/// The words a refusal adds to say what to do next.
///
/// Shared rather than written at each site: `card_not_found` is raised on six
/// paths across two targets, and the offline copy already drifted once — it
/// carried this pointer while the live path did not, and #144 reconciled them
/// by dropping it. A constant makes the divergence impossible instead of
/// merely detectable, which is strictly more than `OfflineParityTests` can buy
/// on its own: a guard fires only once the two texts have already parted.
///
/// Here rather than in `ElliotModel` because it is wire vocabulary, and it
/// belongs beside the code string it explains. `ElliotIPC` is also exactly the
/// intersection of the two targets that need it — `ElliotEngine` and
/// `ElliotMCPKit` both depend on it already, so nothing about the layering
/// moves to share these words.
///
/// ⚠️ **One case, deliberately.** `repo_not_found` was written twice when this
/// type landed, and it is now `ElliotResponse.repoNotFound(name:in:)` — a
/// function rather than a constant here, because that refusal is parameterised
/// on both halves and carries a `code` this enum structurally cannot hold. A
/// constant is the right shape for `card_not_found` and the wrong one for its
/// neighbour; see that factory for the argument.
public enum RefusalHint {
    public static let cardNotFound = "board_list_cards lists the cards this board holds."
}

public enum ElliotResponse: Codable, Sendable {
    case ok(ElliotPayload)
    case failure(code: ElliotErrorCode, message: String, hint: String?)
}

extension ElliotResponse {
    /// The one definition of how Elliot refuses a repository it does not know.
    ///
    /// A **function** rather than a `RefusalHint` constant because this refusal
    /// is parameterised on both halves — the message carries the name that was
    /// asked for, the hint lists the repositories that exist — and once it is a
    /// function it may as well own the `code` too, which is the field
    /// `RefusalHint` cannot hold at all.
    ///
    /// ⛔ **The thing that was duplicated is not a string, it is an answer.**
    /// `MCPRequestHandler.unknownRepo` and `OfflineResponder.filter` each built
    /// all three fields, byte for byte identically, in two targets that must not
    /// import each other. Sharing only the words would leave each caller
    /// assembling the *combination* — and assembling the same reply twice is
    /// precisely the failure mode being closed. Returning the finished
    /// `.failure` makes divergence impossible for all three fields at once.
    ///
    /// ⚠️ `OfflineParityTests.unknownRepoRefusalAgrees` byte-compares the two
    /// paths and would have caught a one-sided edit — but only *after* someone
    /// wrote it, at CI, on a machine that is not theirs. That is the same
    /// argument `RefusalHint` records above: **a guard fires once the two texts
    /// have already parted.** One definition moves the failure to compile time,
    /// where there is nothing to detect because there is nothing to diverge.
    ///
    /// Here rather than in either caller because `ElliotIPC` is the intersection
    /// both already depend on, so nothing about the layering moves — in
    /// particular `ElliotMCPKit` still imports neither `ElliotEngine` nor
    /// `ElliotProcess`.
    public static func repoNotFound(name: String, in repos: [Repo]) -> ElliotResponse {
        .failure(
            code: .repoNotFound,
            message: "No registered repository matches \"\(name)\".",
            hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
        )
    }
}

public enum ElliotPayload: Codable, Sendable {
    case hello(serverVersion: String)
    case cards(CardPage)
    case card(CardDTO)
    case created(CardCreatedDTO)
    case moved(MoveDTO)
    case runs(RunPage)
    case run(RunDTO)
    case repos([RepoDTO])
    case next(NextPage)
    case analysisStarted(AnalysisDTO)
    case proposals([ProposalDTO])
    case proposalsDecided(DecisionDTO)
    case screenshot(ScreenshotDTO)
}

// MARK: - Screenshots

/// One window, photographed, and an honest account of what the photograph does
/// not contain.
///
/// The capture renders Elliot's own view hierarchy in-process, so it needs no
/// Screen Recording grant and works while the window is off-screen and the app
/// is in the background — measured, and the reason the tool exists at all. The
/// price is that anything drawn in a *different* window (an attached sheet, a
/// popover, a menu) and anything belonging to another app is simply absent.
///
/// `notIncluded` is therefore load-bearing rather than decorative. "The popover
/// is not in the picture" and "the popover did not open" must not look alike;
/// this repository has written the second down nine times while the first was
/// true. Anything the capture knows it left out is named here, at capture time,
/// because that is the only moment it is knowable.
public struct ScreenshotDTO: Codable, Sendable, Hashable {
    /// The scene id captured — `board`, `preflight`, … — not the window's title.
    public var window: String
    /// The window's actual title, which is what a human recognises.
    public var title: String
    /// Points, not pixels: `scale` says how many pixels each of these bought.
    public var width: Int
    public var height: Int
    /// The backing scale actually rendered at. Reported rather than assumed to
    /// be 2 — a second display can differ, and a picture whose dimensions nobody
    /// can explain is a picture nobody trusts.
    public var scale: Double
    /// The full-resolution PNG on disk. Always written, always returned, even
    /// when the inline copy was dropped — the lossless sink, exactly as a run's
    /// log file is the lossless sink behind a bounded live stream.
    public var pngPath: String
    /// The inline image, base64. `nil` when it could not be made to fit the
    /// budget; the reply then says why rather than shipping a blank picture.
    public var pngBase64: String?
    /// Size of the inline copy after any downscaling, in encoded bytes.
    public var byteCount: Int
    /// The scale it *was* drawn at, set only when the budget bit. Absent means
    /// the picture is full-size, which is a different statement from "small".
    public var downscaledFrom: Double?
    /// Whether the window was on screen. **`false` is not a failure**: the whole
    /// point is that a background window still photographs at its designed size.
    public var isVisible: Bool
    public var isKeyWindow: Bool
    /// What this picture cannot show, in words — `"attached sheet: New story"`,
    /// `"2 child windows"`. Empty means nothing was left out, and is the only
    /// reading of empty.
    public var notIncluded: [String]

    public init(
        window: String,
        title: String,
        width: Int,
        height: Int,
        scale: Double,
        pngPath: String,
        pngBase64: String?,
        byteCount: Int,
        downscaledFrom: Double? = nil,
        isVisible: Bool,
        isKeyWindow: Bool,
        notIncluded: [String] = []
    ) {
        self.window = window
        self.title = title
        self.width = width
        self.height = height
        self.scale = scale
        self.pngPath = pngPath
        self.pngBase64 = pngBase64
        self.byteCount = byteCount
        self.downscaledFrom = downscaledFrom
        self.isVisible = isVisible
        self.isKeyWindow = isKeyWindow
        self.notIncluded = notIncluded
    }
}

// MARK: - Limits

/// Server-side limits on how much one answer may carry.
///
/// A cap exists so a caller cannot ask for the whole board and get an arbitrary
/// slice of it; the pages then say when the cap bit. Silence about truncation
/// reads exactly like complete coverage, which is the failure this closes.
public enum ElliotPaging {
    public static let cardLimitDefault = 100
    public static let cardLimitMax = 500
    public static let runLimitDefault = 20
    public static let runLimitMax = 200
    public static let nextLimitDefault = 10
    public static let nextLimitMax = 50

    /// Clamps a caller's limit, and reports what they originally asked for when
    /// the cap applied. A non-positive limit means "you decide", not "none".
    public static func clamp(
        _ requested: Int,
        default fallback: Int,
        max cap: Int
    ) -> (limit: Int, cappedFrom: Int?) {
        guard requested > 0 else { return (fallback, nil) }
        guard requested > cap else { return (requested, nil) }
        return (cap, requested)
    }
}

/// How long each side is prepared to wait.
public enum ElliotTimeouts {
    /// Every request except `awaitRun` is a database read behind an actor.
    public static let request: TimeInterval = 30

    /// The window `awaitRun` uses when the caller does not name one.
    public static let awaitDefaultSeconds = 60

    /// The hard ceiling on one `awaitRun`. A caller asking for more is clamped
    /// rather than refused: the answer is still the run, just an earlier
    /// snapshot of it, and they can ask again. An MCP client has its own
    /// patience and a connection held for an hour is a connection nobody
    /// notices dying.
    public static let awaitMaxSeconds = 300

    /// How often the server re-reads the run while waiting.
    public static let awaitPollInterval: TimeInterval = 0.5

    /// Added to the window before the socket gives up, so the server's timeout
    /// is always the one that fires.
    public static let awaitGrace: TimeInterval = 15

    public static func clampAwaitSeconds(_ requested: Int) -> Int {
        guard requested > 0 else { return awaitDefaultSeconds }
        return min(requested, awaitMaxSeconds)
    }
}

// MARK: - Wire shapes
//
// Deliberately not the model types: what an agent reads should stay stable and
// self-describing even as the storage schema moves.
//
// Keys are camelCase throughout — Swift's synthesised `Codable` with no
// `CodingKeys` anywhere, so a property and its wire name cannot drift apart.
// String *values* that name a thing are snake_case (`ElliotErrorCode`,
// `VerifiedOutcomeDTO.kind`, `MoveBlock.code`), which is the convention this
// file already had.

/// A pull request's state as the board last read it, ready to render.
///
/// The facets travel **separately** from the sign, and both travel. A card has
/// room for one mark; an agent reading `board_get_card` has room for the whole
/// picture, and collapsing the three into the headline would hide "green, but in
/// conflict" — a combination this board sees regularly.
///
/// `checks` carries the real names rather than a verdict about them, and that
/// is still true — but not for the reason this comment used to give.
///
/// It said Elliot "deliberately does not decide" that `CodeQL` or
/// `renovate/stability-days` is not a build. Elliot does decide that, since
/// #322: once, in `NonBuildChecks`, read by `ResolvedPRStatus`
/// `.isMergeableUnattended` and by nothing else, because that is the one caller
/// allowed to merge to a default branch on github.com with nobody watching.
///
/// This DTO is unaffected **by design**, not by omission. An agent reading
/// `board_get_card` gets every name that ran so it can judge for itself, and
/// `ci == "no_checks"` states the one thing that needs no list. Discounting
/// names here would hide from the reader exactly what the merge gate is
/// reasoning about.
public struct PRStatusDTO: Codable, Sendable, Hashable {
    /// The most blocking known fact, or absent when there is nothing to report.
    /// Absent here is an *answer*; `"unknown"` is the refusal to give one.
    public var sign: String?
    public var summary: String?
    public var ci: String
    public var merge: String
    public var review: String
    public var checks: [CheckDTO]
    /// When this was read, and on which commit — so a caller can weigh it rather
    /// than trust it.
    public var checkedAt: Date
    public var headRefOid: String
    public var isStale: Bool

    public struct CheckDTO: Codable, Sendable, Hashable {
        public var name: String
        public var conclusion: String?
        public var isPending: Bool
        /// Stated outright rather than left to be derived from `conclusion`.
        ///
        /// `gh` reports a **legacy StatusContext**'s verdict in `state`, not in
        /// `conclusion`, so a failing legacy status arrives here with
        /// `conclusion: null` — indistinguishable from a pass by any reader
        /// inspecting that field alone. `CIState.failing` names the failures but
        /// `code` flattens to `"failing"`, so without this the agent is told
        /// something failed and cannot tell which.
        public var hasFailed: Bool

        public init(
            name: String, conclusion: String? = nil, isPending: Bool = false,
            hasFailed: Bool = false
        ) {
            self.name = name
            self.conclusion = conclusion
            self.isPending = isPending
            self.hasFailed = hasFailed
        }
    }

    public init(
        sign: String? = nil,
        summary: String? = nil,
        ci: String,
        merge: String,
        review: String,
        checks: [CheckDTO] = [],
        checkedAt: Date,
        headRefOid: String,
        isStale: Bool
    ) {
        self.sign = sign
        self.summary = summary
        self.ci = ci
        self.merge = merge
        self.review = review
        self.checks = checks
        self.checkedAt = checkedAt
        self.headRefOid = headRefOid
        self.isStale = isStale
    }

    /// Built from the model's own resolution, never re-derived here — the
    /// precedence order has exactly one implementation and it is in
    /// `ElliotModel`.
    public init(_ status: PRStatus, resolved: ResolvedPRStatus) {
        sign = resolved.sign?.code
        summary = resolved.sign?.summary
        ci = resolved.ci.code
        merge = resolved.merge.code
        review = resolved.review.code
        checks = resolved.isStale
            ? []
            : status.checks.map {
                CheckDTO(
                    name: $0.label, conclusion: $0.conclusion,
                    isPending: $0.isPending, hasFailed: $0.hasFailed)
            }
        checkedAt = resolved.checkedAt
        headRefOid = resolved.headRefOid
        isStale = resolved.isStale
    }
}

public struct CardDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var column: String
    public var repo: String
    public var story: StoryDTO?
    public var body: String?
    public var issueNumber: Int?
    public var issueURL: String?
    public var prNumber: Int?
    public var prURL: String?
    public var branch: String?
    public var lastError: String?
    /// Set when the card is held by a run, which is why a move would be refused.
    ///
    /// Absent means "no run holds this card" and nothing else. A reader that
    /// cannot establish that — an offline snapshot that skipped the lookup —
    /// must say so in its own note rather than leave this nil, or every held
    /// card reads as movable.
    public var activeRunID: UUID?

    /// What GitHub says about this card's pull request, when a reading exists.
    ///
    /// Absent means Elliot has not read one — a card outside In Review, a card
    /// with no pull request, or one nothing has looked at yet. It does **not**
    /// mean the pull request is fine, which is why there is no "all clear" value:
    /// the caller has to distinguish "no reading" from "a reading with nothing to
    /// report", and only the presence of the object can do that.
    public var prStatus: PRStatusDTO?

    public struct StoryDTO: Codable, Sendable, Hashable {
        public var role: String
        public var want: String
        public var benefit: String
        public var acceptanceCriteria: [String]
        public var narrative: String

        public init(_ story: UserStory) {
            role = story.role
            want = story.want
            benefit = story.benefit
            acceptanceCriteria = story.acceptanceCriteria
            narrative = story.narrative
        }

        public init(
            role: String,
            want: String,
            benefit: String,
            acceptanceCriteria: [String],
            narrative: String
        ) {
            self.role = role
            self.want = want
            self.benefit = benefit
            self.acceptanceCriteria = acceptanceCriteria
            self.narrative = narrative
        }
    }

    public init(
        card: Card, repoName: String, activeRunID: UUID? = nil, prStatus: PRStatusDTO? = nil
    ) {
        id = card.id
        title = card.displayTitle
        column = card.column.rawValue
        repo = repoName
        story = card.story.map(StoryDTO.init)
        body = card.body.isEmpty ? nil : card.body
        issueNumber = card.issueNumber
        issueURL = card.issueURL
        prNumber = card.prNumber
        prURL = card.prURL
        branch = card.branch
        lastError = card.lastError
        self.activeRunID = activeRunID
        self.prStatus = prStatus
    }

    /// Field by field, so a test can state the shape it expects without
    /// building a `Card` and a repository to get there.
    public init(
        id: UUID,
        title: String,
        column: String,
        repo: String,
        story: StoryDTO? = nil,
        body: String? = nil,
        issueNumber: Int? = nil,
        issueURL: String? = nil,
        prNumber: Int? = nil,
        prURL: String? = nil,
        branch: String? = nil,
        lastError: String? = nil,
        activeRunID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.column = column
        self.repo = repo
        self.story = story
        self.body = body
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.prNumber = prNumber
        self.prURL = prURL
        self.branch = branch
        self.lastError = lastError
        self.activeRunID = activeRunID
    }
}

/// The answer to `createCard`, which may not have created anything.
public struct CardCreatedDTO: Codable, Sendable, Hashable {
    public var card: CardDTO
    /// True when `idempotencyKey` matched a card that already existed. The
    /// retry of a request that timed out on the way back is not a second card.
    public var alreadyExisted: Bool

    public init(card: CardDTO, alreadyExisted: Bool) {
        self.card = card
        self.alreadyExisted = alreadyExisted
    }
}

public struct RepoDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var nameWithOwner: String
    public var displayName: String
    public var path: String
    public var defaultBranch: String
    /// A disabled repository blocks every triggering move with `repo_disabled`.
    public var isEnabled: Bool
    /// The `claude --permission-mode` runs in this repository get. Surfaced
    /// because `bypassPermissions` is what makes a card move an execution
    /// primitive, and an agent choosing where to file work should be able to
    /// see that before it moves anything.
    public var permissionMode: String

    public init(repo: Repo) {
        id = repo.id
        nameWithOwner = repo.nameWithOwner
        displayName = repo.displayName
        path = repo.path
        defaultBranch = repo.defaultBranch
        isEnabled = repo.isEnabled
        permissionMode = repo.permissionMode.rawValue
    }

    public init(
        id: UUID,
        nameWithOwner: String,
        displayName: String,
        path: String,
        defaultBranch: String,
        isEnabled: Bool,
        permissionMode: String
    ) {
        self.id = id
        self.nameWithOwner = nameWithOwner
        self.displayName = displayName
        self.path = path
        self.defaultBranch = defaultBranch
        self.isEnabled = isEnabled
        self.permissionMode = permissionMode
    }
}

public struct MoveDTO: Codable, Sendable, Hashable {
    public var cardID: UUID
    public var from: String
    public var to: String
    /// The run the move started, if it triggered one.
    public var runID: UUID?
    public var triggered: String?
    /// When a run started: how long to wait before the first check. Answering
    /// this here is what stops an agent hammering the socket for forty minutes.
    public var pollAfterSeconds: Int?
    /// Plain-language account of what the move did, for the agent to relay.
    public var summary: String

    public init(
        cardID: UUID,
        from: String,
        to: String,
        runID: UUID?,
        triggered: String?,
        pollAfterSeconds: Int? = nil,
        summary: String
    ) {
        self.cardID = cardID
        self.from = from
        self.to = to
        self.runID = runID
        self.triggered = triggered
        self.pollAfterSeconds = pollAfterSeconds
        self.summary = summary
    }
}

// MARK: - Runs

/// What `gh` established, flattened into one tagged object.
///
/// Not `VerifiedOutcome`'s own `Codable`. Swift synthesises
/// `{"issueCreated":{"number":1,"url":"…"}}` for an enum with associated
/// values: the shape changes with every case rename, and a model reading it has
/// to know the case names before it can find the tag. A flat `kind` plus
/// optional fields is stable under refactoring and readable at a glance.
///
/// `kind` is one of `issue_created`, `no_issue_created`, `pr_open`, `merged`,
/// `not_merged`, `closed_unmerged`, `unverified`.
public struct VerifiedOutcomeDTO: Codable, Sendable, Hashable {
    public var kind: String
    public var number: Int?
    public var url: String?
    public var isDraft: Bool?
    public var branch: String?
    public var commitSHA: String?
    /// Why nothing was created, merged or verified. The only field that is
    /// prose, and the only one where prose is the answer.
    public var reason: String?

    public init(
        kind: String,
        number: Int? = nil,
        url: String? = nil,
        isDraft: Bool? = nil,
        branch: String? = nil,
        commitSHA: String? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.number = number
        self.url = url
        self.isDraft = isDraft
        self.branch = branch
        self.commitSHA = commitSHA
        self.reason = reason
    }

    /// Exhaustive by construction: no `default`, so a new `VerifiedOutcome`
    /// case fails the build here instead of reaching the agent as silence.
    public init(_ outcome: VerifiedOutcome) {
        switch outcome {
        case .issueCreated(let number, let url):
            self.init(kind: "issue_created", number: number, url: url)
        case .noIssueCreated(let reason):
            self.init(kind: "no_issue_created", reason: reason)
        case .prOpen(let number, let url, let isDraft, let branch):
            self.init(kind: "pr_open", number: number, url: url, isDraft: isDraft, branch: branch)
        case .merged(let commitSHA, let number, let url, let branch):
            self.init(kind: "merged", number: number, url: url, branch: branch, commitSHA: commitSHA)
        case .notMerged(let reason):
            self.init(kind: "not_merged", reason: reason)
        case .closedUnmerged(let number, let url, let branch):
            self.init(kind: "closed_unmerged", number: number, url: url, branch: branch)
        case .unverified(let reason):
            self.init(kind: "unverified", reason: reason)
        }
    }
}

/// What an analysis run had to say about itself, flattened for the wire.
///
/// Its own type rather than `AnalysisRunReport` re-exported, for the reason
/// `VerifiedOutcomeDTO` is its own type: what an agent reads must not be a
/// model type's synthesised `Codable`, or renaming a field in `ElliotModel`
/// changes the wire with nothing at the boundary to fail.
public struct AnalysisReportDTO: Codable, Sendable, Hashable {
    /// `artifact` when the stories came from the file the prompt asked for,
    /// `resultText` when they had to be recovered from the closing message,
    /// `none` when there were none to read.
    public var source: String
    /// Proposals that survived validation.
    public var kept: Int
    /// Why each dropped story was dropped. Shown, never swallowed.
    public var dropped: [String]
    /// The git sentinel, and it is tri-state on purpose.
    ///
    /// **Absent** means nobody checked: the baseline lives only in the running
    /// app, so a run orphaned by a crash has nothing to compare against.
    /// `false` means it was checked and the tree was untouched. Reading absent
    /// as clean is asserting something about a repository nobody looked at.
    public var workingTreeChanged: Bool?
    /// `git status --porcelain` after the run, present only when it moved.
    public var workingTreeDiff: String?

    public init(
        source: String,
        kept: Int = 0,
        dropped: [String] = [],
        workingTreeChanged: Bool? = nil,
        workingTreeDiff: String? = nil
    ) {
        self.source = source
        self.kept = kept
        self.dropped = dropped
        self.workingTreeChanged = workingTreeChanged
        self.workingTreeDiff = workingTreeDiff
    }

    public init(_ report: AnalysisRunReport) {
        source = report.harvestSource.rawValue
        kept = report.kept
        dropped = report.dropped
        workingTreeChanged = report.workingTreeChanged
        workingTreeDiff = report.workingTreeDiff
    }
}

public struct RunDTO: Codable, Sendable, Hashable {
    public var id: UUID
    /// Null for an analysis run, which reads a repository and has no card.
    public var cardID: UUID?
    /// The analysis this run belongs to. Exactly one of `cardID` and
    /// `analysisID` is set.
    public var analysisID: UUID?
    /// The lens this run read the repository through: `bugs`, `quickWins`,
    /// `features`, `techDebt`, `tests` or `docsAndDX`. Null for a card run.
    ///
    /// True from the moment the run is queued, unlike `analysisReport` — an
    /// agent watching a running analysis still needs to know which of six
    /// readings it is watching.
    public var angle: String?
    /// `create-issue`, `implement-issue`, `merge-pr` or `analyze-repo` — the
    /// same vocabulary `MoveDTO.triggered` and `NextDTO.wouldTrigger` use, so
    /// one word means one thing across the whole wire.
    public var kind: String
    public var state: String
    /// `state` is not enough on its own: `succeeded` is compatible with an
    /// outcome of `no_issue_created`, `not_merged` and `unverified`. These two
    /// flags spare the agent a table it would otherwise have to guess at.
    public var isTerminal: Bool
    public var isActive: Bool
    /// What `gh` established, as opposed to what the agent said it did.
    ///
    /// This is the field to read. A run can succeed without merging anything;
    /// `resultText` will still describe a merge, because that is the agent's
    /// account of its own work and not a fact.
    public var verifiedOutcome: VerifiedOutcomeDTO?
    /// What the run had to say about itself: where its stories came from, what
    /// was dropped, and whether the repository moved under it. Null for a card
    /// run, and for an analysis run that has not finished.
    public var analysisReport: AnalysisReportDTO?
    public var exitCode: Int32?
    public var prompt: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var totalCostUSD: Double?
    public var numTurns: Int?
    /// The run's closing text. Display only — never parse it for issue or PR
    /// numbers; that is what `verifiedOutcome` is for.
    public var resultText: String?
    /// Whose words `resultText` is: `agent`, `stderr` or `elliot`.
    ///
    /// ⚠️ Read it before quoting the text as the agent's. `agent` is the
    /// terminal event's own `result` field; `stderr` is what the process left
    /// behind when it died before emitting one, and is a fact rather than a
    /// claim; `elliot` is a sentence the board wrote about a run that could not
    /// be started or was orphaned by a crash — on those paths no agent ever
    /// spoke. **Absent** means the run finished before this was recorded, which
    /// is an absence of a record and not a fourth kind.
    public var resultSource: String?
    public var permissionDenials: [String]
    /// NDJSON, one Claude Code `stream-json` event per line.
    public var logPath: String
    public var stderrPath: String
    /// When to look again, in seconds. `nil` once the run is terminal: there is
    /// nothing left to poll for, and saying so is what ends the loop.
    public var pollAfterSeconds: Int?

    /// `now` is injected rather than read, so the backoff is reproducible in a
    /// test and two DTOs built from the same run compare equal.
    public init(run: SkillRun, now: Date = Date()) {
        id = run.id
        cardID = run.cardID
        analysisID = run.analysisID
        angle = run.analysisAngle?.rawValue
        kind = run.kind.skillName
        state = run.state.rawValue
        isTerminal = run.state.isTerminal
        isActive = run.state.isActive
        verifiedOutcome = run.verifiedOutcome.map(VerifiedOutcomeDTO.init)
        analysisReport = run.analysisReport.map(AnalysisReportDTO.init)
        exitCode = run.exitCode
        prompt = run.prompt
        startedAt = run.startedAt
        endedAt = run.endedAt
        totalCostUSD = run.totalCostUSD
        numTurns = run.numTurns
        resultText = run.resultText
        resultSource = run.resultSource?.rawValue
        permissionDenials = run.permissionDenials
        logPath = run.logPath
        stderrPath = run.stderrPath
        pollAfterSeconds = Self.pollAfterSeconds(
            state: run.state,
            age: now.timeIntervalSince(run.startedAt ?? run.createdAt)
        )
    }

    public init(
        id: UUID,
        cardID: UUID?,
        analysisID: UUID? = nil,
        angle: String? = nil,
        kind: String,
        state: String,
        isTerminal: Bool,
        isActive: Bool,
        verifiedOutcome: VerifiedOutcomeDTO? = nil,
        analysisReport: AnalysisReportDTO? = nil,
        exitCode: Int32? = nil,
        prompt: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        totalCostUSD: Double? = nil,
        numTurns: Int? = nil,
        resultText: String? = nil,
        resultSource: String? = nil,
        permissionDenials: [String] = [],
        logPath: String,
        stderrPath: String,
        pollAfterSeconds: Int? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.analysisID = analysisID
        self.angle = angle
        self.kind = kind
        self.state = state
        self.isTerminal = isTerminal
        self.isActive = isActive
        self.verifiedOutcome = verifiedOutcome
        self.analysisReport = analysisReport
        self.exitCode = exitCode
        self.prompt = prompt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalCostUSD = totalCostUSD
        self.numTurns = numTurns
        self.resultText = resultText
        self.resultSource = resultSource
        self.permissionDenials = permissionDenials
        self.logPath = logPath
        self.stderrPath = stderrPath
        self.pollAfterSeconds = pollAfterSeconds
    }

    /// Backs off with the run's age. A `merge-pr` waiting on CI can run for
    /// hours; checking it every second buys nothing and costs a round trip per
    /// second for the whole of it.
    public static func pollAfterSeconds(state: RunState, age: TimeInterval) -> Int? {
        guard !state.isTerminal else { return nil }
        switch age {
        case ..<60: return 5
        case ..<600: return 15
        case ..<1800: return 30
        default: return 60
        }
    }
}

// MARK: - Pages

/// Cards matching a filter, and the truth about how many were left out.
///
/// `total` counts everything the filter matched, before the limit. `truncated`
/// is derived from it at construction so no producer can forget to set it —
/// which is the whole point, since a short list with no count is
/// indistinguishable from a complete one.
public struct CardPage: Codable, Sendable, Hashable {
    public var cards: [CardDTO]
    public var total: Int
    /// The limit actually applied.
    public var limit: Int
    public var truncated: Bool
    /// Set when the caller asked for more than `ElliotPaging.cardLimitMax`.
    public var limitCappedFrom: Int?

    public init(cards: [CardDTO], total: Int, limit: Int, limitCappedFrom: Int? = nil) {
        self.cards = cards
        self.total = total
        self.limit = limit
        truncated = total > cards.count
        self.limitCappedFrom = limitCappedFrom
    }
}

public struct RunPage: Codable, Sendable, Hashable {
    public var runs: [RunDTO]
    public var total: Int
    public var limit: Int
    public var truncated: Bool
    public var limitCappedFrom: Int?

    public init(runs: [RunDTO], total: Int, limit: Int, limitCappedFrom: Int? = nil) {
        self.runs = runs
        self.total = total
        self.limit = limit
        truncated = total > runs.count
        self.limitCappedFrom = limitCappedFrom
    }
}

// MARK: - What to do next

/// Why a card's next move is not available, when the reason is not a
/// `MoveBlock`.
///
/// Kept apart from `MoveBlock.code` on purpose: those codes are the rule
/// engine's own vocabulary and `board_move_card` returns them verbatim. These
/// two describe a card the engine simply has nothing to say about.
public enum NextBlockCode {
    /// The move is allowed and triggers nothing. A card in progress advances
    /// when Elliot notices its pull request went ready — there is no gesture
    /// for an agent to make here.
    public static let nothingToTrigger = "nothing_to_trigger"
    /// The rule engine asked for an argument this request did not carry.
    public static let needsInput = "needs_input"
}

/// One card and the move it is waiting for.
public struct NextDTO: Codable, Sendable, Hashable {
    public var card: CardDTO
    /// Where this card goes next. Board order, one step.
    public var nextColumn: String
    /// `create-issue`, `implement-issue`, `merge-pr`, or absent when the move
    /// would trigger nothing.
    public var wouldTrigger: String?
    /// Whether moving it right now would actually start that work.
    public var isReady: Bool
    /// A `MoveBlock.code`, or one of `NextBlockCode`. Stable, and the same
    /// string `board_move_card` would return if the move were attempted.
    public var blockCode: String?
    public var blockReason: String?
    public var blockHint: String?
    /// 1-based position in this answer, so the agent can quote a rank back
    /// without re-deriving the order.
    public var rank: Int
    /// One sentence that stands on its own, for an agent that reads the summary
    /// and nothing else.
    public var summary: String

    public init(
        card: CardDTO,
        nextColumn: String,
        wouldTrigger: String? = nil,
        isReady: Bool,
        blockCode: String? = nil,
        blockReason: String? = nil,
        blockHint: String? = nil,
        rank: Int,
        summary: String
    ) {
        self.card = card
        self.nextColumn = nextColumn
        self.wouldTrigger = wouldTrigger
        self.isReady = isReady
        self.blockCode = blockCode
        self.blockReason = blockReason
        self.blockHint = blockHint
        self.rank = rank
        self.summary = summary
    }
}

/// The board's answer to "what should I do next".
///
/// Ordered by `rankNextSteps`, which is pure and total: ready before blocked,
/// then nearest to done first — finishing work that is already in flight beats
/// starting more — then repository name, position in column, and id. Two calls
/// against an unchanged board return the same order in the same sequence.
///
/// Blocked cards are included rather than filtered out. "Nothing is ready and
/// here is why" is an answer; an empty list is not.
public struct NextPage: Codable, Sendable, Hashable {
    public var items: [NextDTO]
    /// Cards considered, before the limit. Cards in `done` are not candidates:
    /// they have nowhere to go.
    public var total: Int
    public var limit: Int
    public var truncated: Bool
    public var limitCappedFrom: Int?
    /// How many of the *candidates* are ready, not just of `items`. An agent
    /// that sees `readyCount: 0` knows the board is waiting on something, not
    /// that it asked for too few rows.
    public var readyCount: Int

    public init(
        items: [NextDTO],
        total: Int,
        limit: Int,
        readyCount: Int,
        limitCappedFrom: Int? = nil
    ) {
        self.items = items
        self.total = total
        self.limit = limit
        truncated = total > items.count
        self.readyCount = readyCount
        self.limitCappedFrom = limitCappedFrom
    }
}

public struct AnalysisRunDTO: Codable, Sendable, Hashable {
    public var runID: UUID
    public var angle: String
    public var state: String

    public init(runID: UUID, angle: String, state: String) {
        self.runID = runID
        self.angle = angle
        self.state = state
    }
}

public struct AnalysisDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var repo: String
    public var angles: [String]
    public var maxStoriesPerAngle: Int
    public var createdAt: Date
    public var runs: [AnalysisRunDTO]

    public init(analysis: Analysis, repoName: String, runs: [AnalysisRunDTO]) {
        id = analysis.id
        repo = repoName
        angles = analysis.angles.map(\.rawValue)
        maxStoriesPerAngle = analysis.maxStoriesPerAngle
        createdAt = analysis.createdAt
        self.runs = runs
    }
}

public struct ProposalDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var analysisID: UUID
    public var repo: String
    public var angle: String
    public var title: String
    public var story: CardDTO.StoryDTO
    public var rationale: String
    /// `path:line`, as cited. See `grounded` for whether they were found.
    public var evidence: [String]
    /// Every cited file was found in the repository. A proposal that is not
    /// grounded may still be right — but it was not checkable.
    public var grounded: Bool
    public var effort: String
    public var status: String
    public var duplicateHint: String?
    public var acceptedCardID: UUID?

    public init(proposal: StoryProposal, repoName: String) {
        id = proposal.id
        analysisID = proposal.analysisID
        repo = repoName
        angle = proposal.angle.rawValue
        title = proposal.title
        story = CardDTO.StoryDTO(proposal.story)
        rationale = proposal.rationale
        evidence = proposal.evidence.map(\.display)
        grounded = proposal.isGrounded
        effort = proposal.effort.rawValue
        status = proposal.status.rawValue
        duplicateHint = proposal.duplicateOf?.label
        acceptedCardID = proposal.acceptedCardID
    }
}

public struct DecisionDTO: Codable, Sendable, Hashable {
    /// For `acceptProposals`, this is exact: an id lands here only when its
    /// proposal now links to one of `cards`, so a caller that lost a race
    /// against a concurrent accept is correctly left out. For
    /// `rejectProposals` there is no equivalent evidence to check against —
    /// see `MCPRequestHandler.decide` — so this only means "named a proposal
    /// that exists," not "this call is the one that rejected it."
    public var decided: [UUID]
    public var skipped: [UUID]
    public var cards: [CardDTO]
    /// Plain-language account for the agent to relay.
    public var summary: String

    public init(decided: [UUID], skipped: [UUID], cards: [CardDTO], summary: String) {
        self.decided = decided
        self.skipped = skipped
        self.cards = cards
        self.summary = summary
    }
}

// MARK: - Framing

/// One request or response per line of JSON, correlated by `id`.
public struct Envelope<Body: Codable & Sendable>: Codable, Sendable {
    public var id: UUID
    public var body: Body

    public init(id: UUID = UUID(), body: Body) {
        self.id = id
        self.body = body
    }
}

public enum WireCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encodeLine<T: Codable & Sendable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Codable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
