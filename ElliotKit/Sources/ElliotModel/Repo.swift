import Foundation

/// A registered git repository the board can drive.
///
/// `path` must be the **main checkout**, never a linked worktree: `merge-pr`
/// tears down the PR's worktree and cannot do that from inside it.
public struct Repo: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    /// `owner/name`, resolved once via `gh repo view --json nameWithOwner`.
    /// Every verifier passes it as `--repo` rather than relying on cwd.
    public var nameWithOwner: String
    public var defaultBranch: String
    public var displayName: String

    /// Passed to `claude --permission-mode`. Per-repo so a single repo can be
    /// tightened without touching the others.
    public var permissionMode: PermissionMode
    public var extraAllowedTools: [String]
    public var isEnabled: Bool

    /// GitHub's visibility, kept so the expected path is recomputable offline.
    public var visibility: RepoVisibility?

    /// What Preflight last said about this checkout.
    ///
    /// Stored on the registration rather than held in memory because the rule
    /// that needs it runs in `BoardService.proposeMove`, which already loads
    /// this row — so the verdict arrives with no new collaborator and no second
    /// source of truth. `AppModel` held it in `repoChecks` and no rule could
    /// reach it, which is exactly how the gate came to be asserted in three
    /// documents and implemented in none.
    ///
    /// It is a *measurement* living on a *registration*, so it can go stale. The
    /// bound is that the sweep rewrites it — at startup, on "Check again", and
    /// after a fix is applied — so a repaired repository clears at the next
    /// sweep rather than staying frozen. `notChecked` is what a row migrated
    /// from before this column holds, and it does not block.
    ///
    /// ⚠️ **Optional, and it has to be.** `BoardStore.openReadOnly` deliberately
    /// accepts a database *older* than the helper (`applied.isSubset(of: known)`)
    /// so the board is not blanked between upgrading the bundle and the next
    /// launch of the app — and that tolerance is precisely "an added column
    /// reads as absent", which only holds for an optional. Declared
    /// non-optional, this threw `GRDB.RowDecodingError` and made the helper
    /// refuse **every card** on a pre-v9 database. `OlderDatabaseTests` caught
    /// it, which is the second time that suite has caught this exact class of
    /// regression; #174 was the first.
    ///
    /// Read it through ``preflightVerdict``, never directly — `nil` is a state,
    /// not a missing value, and it means the same thing as `.notChecked`.
    public var preflight: PreflightState?

    /// The labels *this* repository requires, or `nil` if nobody has chosen.
    ///
    /// ⚠️ **`nil` and `[]` are different answers and the difference is the whole
    /// point** (#199, #200). `nil` means the taxonomy question has never been
    /// put to this repository, so `LabelPolicy.default` — Elliot's floor —
    /// applies and Preflight still offers to have the conversation. `[]` means
    /// this repository was asked and chose to require nothing, which is a
    /// decision and must not be nagged again.
    ///
    /// Elliot drives *other people's* repositories and their taxonomies are not
    /// Elliot's. The floor shipped in #172 deliberately set to GitHub's four
    /// stock labels so the mechanism could land without an argument about
    /// taxonomy; this is that argument's answer, per repository.
    ///
    /// ⛔ **Optional, and it has to be** — the same reason ``preflight`` is.
    /// `BoardStore.openReadOnly` accepts a database older than the code reading
    /// it, and that tolerance is exactly "an added column reads as absent",
    /// which only holds for an optional. Declared non-optional this throws
    /// `GRDB.RowDecodingError` and the helper refuses every repository.
    ///
    /// Read it through ``LabelPolicy/resolved(for:)``, never directly: that is
    /// the one place `nil` becomes the floor, and it returns *whose* policy it
    /// gave you along with it.
    public var labelPolicy: [RequiredLabel]?

    /// What the rule engine reads: the verdict, with "this row predates the
    /// column" folded into "nobody has swept it".
    ///
    /// One computed property rather than `?? .notChecked` at each of the four
    /// call sites. The whole defect being fixed here is a verdict that was
    /// spelled out in several places and reachable from none of the ones that
    /// mattered; four hand-written coalescings would be that shape returning.
    public var preflightVerdict: PreflightState { preflight ?? .notChecked }

    /// Which method pack this repository's transitions run.
    ///
    /// ⚠️ **Optional, for `preflight`'s reason plus one of its own.**
    /// `BoardStore.openReadOnly` deliberately accepts a database *older* than
    /// the helper (`applied.isSubset(of: known)`), and that tolerance is
    /// precisely "an added column reads as absent" — which only holds for an
    /// optional. On top of that, Swift's synthesised decoder **ignores a
    /// property's default value**: it emits `decode(_:forKey:)`, never
    /// `decodeIfPresent`, so `methodID: String = "ai-migration-kit"` would
    /// compile, read correctly everywhere the app looks, and throw
    /// `keyNotFound` on every database predating the column — refusing every
    /// repository in exactly the window `openReadOnly` exists to serve.
    /// `RepoMethodMigrationTests` is what says so.
    ///
    /// Read it through ``method``, never directly: `nil` is a state — *never
    /// chosen* — not a missing value, and it is emphatically not the same state
    /// as an id the catalogue does not know.
    public var methodID: String?

    /// The three-valued answer, modelled on ``preflightVerdict``.
    ///
    /// Not `?? aiMigrationKit`: folding an unknown id into a working pack would
    /// run another method's commands in this checkout, at `bypassPermissions`,
    /// with nothing reporting it. The fold this accessor *does* perform — NULL
    /// to `.unset` — is a resolution rather than a substitution, and it stays
    /// distinguishable because `.unknown` is a third value rather than the same
    /// one.
    ///
    /// ⚠️ Nothing in this task acts on `.unknown`. Turning it into a Preflight
    /// `.fail` is **Task 6**; refusing the move is **Task 7**. Saying otherwise
    /// here would be the shape `PreflightState`'s header warns about — three
    /// documents asserting a gate nobody had written.
    public var method: MethodResolution { MethodCatalog.resolve(methodID) }

    public init(
        id: UUID = UUID(),
        path: String,
        nameWithOwner: String,
        defaultBranch: String = "main",
        displayName: String,
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = [],
        isEnabled: Bool = true,
        visibility: RepoVisibility? = nil,
        preflight: PreflightState? = nil,
        labelPolicy: [RequiredLabel]? = nil,
        methodID: String? = nil
    ) {
        self.labelPolicy = labelPolicy
        self.id = id
        self.path = path
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
        self.displayName = displayName
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.isEnabled = isEnabled
        self.visibility = visibility
        self.preflight = preflight
        self.methodID = methodID
    }
}

/// Mirrors `claude --permission-mode`'s accepted values.
///
/// `manual` is the CLI's alias for the internal `default`; we store the alias
/// the CLI advertises in `--help`.
public enum PermissionMode: String, Codable, CaseIterable, Sendable, Hashable {
    case manual
    case acceptEdits
    case auto
    case dontAsk
    case plan
    case bypassPermissions
}

public extension PermissionMode {
    /// The mode an appraisal runs under: never `bypassPermissions`, whatever
    /// the repository is set to.
    ///
    /// Deliberately not the repository's own mode. An appraisal inherits the
    /// operator's MCP configuration, so its agent can see the `elliot` server
    /// and call `board_move_card` — a run driving the board it is supposed to
    /// be reporting on. `bypassPermissions` grants tool calls without asking,
    /// which is the whole of its name and the one mode this project has
    /// actually run, so under it that call is granted in silence and the run
    /// can end "success" having moved a card. What the cap is *for* is refusing
    /// that call in the first place, and that half is intact: under every mode
    /// this returns, `PermissionPolicy` declines each request rather than
    /// granting it.
    ///
    /// ⛔ **The other half — that the refusal is then visible on the card — no
    /// longer holds under ACP, and this comment asserted it until the final
    /// review traced it.** It used to read: *"a refused tool puts its name in
    /// `permissionDenials`, and `RunScheduler.state(for:)` then ends the run
    /// `.completedWithDenials`."* Under the CLI that was true, because Claude
    /// Code was both the authority and the reporter: it refused the call and
    /// wrote `permission_denials` into its own result JSON. Under ACP the two
    /// come apart. **Elliot** is the authority — `PermissionPolicy` answers the
    /// request — but `permissionDenials` is fed only by the *adapter's*
    /// `_meta.claudeCode.nonExecutionKind` frames. `PermissionPolicy.refusals()`
    /// reaches the log file and nothing else: `AgentLog.events` skips that
    /// method, so it reaches neither the card nor the panel.
    ///
    /// So a run in which Elliot itself declined every tool call can still be
    /// filed `.succeeded`. Whether the adapter mirrors a client-side denial back
    /// as a `permission-rule` frame is **UNMEASURED** — the design records it as
    /// such, and one probe would settle it. Carrying the ledger into
    /// `AgentRunOutcome` is the fix, and it changes run-verdict semantics, so it
    /// is tracked rather than smuggled in here.
    ///
    /// ⚠️ An allow-list of **names**, and not a measured ranking. Apart from
    /// `bypassPermissions`, no mode here has ever been run by this project and
    /// the CLI documents no semantics for any of them — so this cannot claim
    /// that `.acceptEdits` refuses an MCP call, nor that it is in fact narrower
    /// than `.auto` or `.dontAsk`. It is a conservative choice over names. The
    /// one property that is asserted as a guarantee is negative, and it is the
    /// one the tests pin: the answer is never `bypassPermissions`.
    ///
    /// A repository pinned to `.plan` keeps `.plan`, even though such a run may
    /// not be able to write its artifact at all — the harvester then reports
    /// "no artifact", which is honest, and beats overriding a mode the operator
    /// chose deliberately.
    ///
    /// A `switch` over every case: a seventh mode is a compile error here
    /// rather than a silent default into whichever arm someone wrote first.
    static func appraisal(repo: PermissionMode) -> PermissionMode {
        switch repo {
        case .plan, .manual, .acceptEdits: repo
        case .auto, .dontAsk, .bypassPermissions: .acceptEdits
        }
    }
}
