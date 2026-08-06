import Foundation

/// Which of the board's four screens is the true one.
///
/// A rule rather than a chain of `if`s in `BoardView`, and here rather than in
/// `ElliotAppKit`, because the defect it exists to prevent is **two surfaces
/// disagreeing** (#118): the board rendered "Still starting" from
/// `hasLoadedRepos` while the status line under it rendered "Ready." from
/// `isReady`, for ever, because the two were decided in different places from
/// different facts and nothing owned the pair.
///
/// So the phase owns both. A caller cannot draw the starting screen while
/// claiming readiness, because `of(…)` will not return `.starting` when
/// `isReady` — and that is asserted rather than described.
public enum BoardPhase: Sendable, Hashable {
    /// Startup is genuinely still running.
    case starting
    /// The repositories could not be read, or never arrived at all.
    case unreadable(reason: String)
    /// The store is readable and holds nothing. Deliberately **not** the same
    /// screen as `.unreadable` — that conflation is what #42 was.
    case empty
    /// Draw the board.
    case ready

    /// What the board is really doing, from the four facts that decide it.
    ///
    /// `isReady` is set by `start()` when the login shell, the tool lookups and
    /// the preflight sweep have finished; `hasLoadedRepos` is set by the
    /// repository observation's first delivery. They are independent, and the
    /// bug is the state where the first is true and the second never becomes
    /// true: nothing is still happening, so "still starting" is false, and the
    /// old code said it anyway with "Ready." underneath.
    ///
    /// That state is reported **without needing the error**, which matters:
    /// an observation that throws is only one way to reach it, and a delivery
    /// that simply never arrives reaches it too, with nothing caught anywhere.
    public static func of(
        hasLoadedRepos: Bool, isReady: Bool, repoCount: Int, failure: String?
    ) -> BoardPhase {
        // A failure that arrived after a good delivery does not blank the
        // board: the caller keeps the repositories it has and shows the reason
        // beside them. Only an unreadable *first* delivery takes the screen.
        if !hasLoadedRepos {
            if let failure { return .unreadable(reason: failure) }
            return isReady ? .unreadable(reason: Self.neverArrived) : .starting
        }
        return repoCount == 0 ? .empty : .ready
    }

    /// The reason given when nothing threw and nothing arrived.
    ///
    /// Names the observation rather than blaming the store, because at this
    /// point Elliot genuinely does not know which it was — and saying more than
    /// it knows is the failure mode this whole change is about.
    public static let neverArrived =
        "Startup finished, but the list of repositories never arrived."

    /// The screen's title, or `nil` when the board itself is drawn.
    public var title: String? {
        switch self {
        case .starting: "Still starting"
        case .unreadable: "Could not read your repositories"
        case .empty: "No repository yet"
        case .ready: nil
        }
    }

    /// The line under the title.
    ///
    /// `status` is only consulted for `.starting`, and that is the whole point:
    /// it is a shared line the next event overwrites, so it is trustworthy only
    /// while startup is genuinely running — which is exactly when this returns
    /// it. Once `isReady` is true `of(…)` never answers `.starting`, so the
    /// pairing that produced "Still starting / Ready." cannot be built.
    public func detail(status: String) -> String? {
        switch self {
        case .starting: status
        case .unreadable(let reason): reason
        case .empty: nil
        case .ready: nil
        }
    }

    /// Whether the reader is being told something went wrong, as opposed to
    /// being asked to wait or to add a repository.
    public var isFailure: Bool {
        if case .unreadable = self { return true }
        return false
    }
}
