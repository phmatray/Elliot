import ElliotModel
import Foundation

/// One thing the reader can do about a refused analysis.
///
/// The third screen to carry one: `RepoFix` has been the Repositories page's
/// since #12 and `CheckFix` Preflight's since #170, and the analysis footer
/// could only ever *describe* a remedy — while
/// `AnalysisFooterMessage.setup`'s own precedence order ranks the refusal above
/// the failure, the clash and the consequence **because it is the only one of
/// the four that names something to go and do**, and then handed the reader a
/// sentence.
///
/// ⚠️ **#294 called this "the last diagnostic in the app that is prose only",
/// and that is not true — do not repeat it.** Measured while implementing it:
/// `AppModel.refusal` (a refused move, on the card), `AppModel.newStoryRefusal`
/// (under *Add to backlog*) and `ConsoleLayout.refusal` (a window too short to
/// unfold a screen) are all sentences with nothing beside them, and each of the
/// three is right to be — the first two name a gap in what the reader typed and
/// the third names the window. What *is* verifiable here is narrower and
/// enough: this footer ranked its refusal top for naming something to go and do,
/// and then offered no way to do it.
///
/// ⛔ **Every case is deterministic, and that is a rule rather than how the
/// three happened to turn out.** `CheckFix` records the choice at length:
/// `createLabels` runs `gh` directly because there is one right answer and
/// nothing committed, `seedCard` goes on the board because choosing a taxonomy
/// is a judgement that edits a committed file. Pointing the picker, flipping a
/// switch and unfolding a console are all the first kind, so none of them may
/// reach an unattended `claude -p`. A second place that starts a run, outside
/// the board, would quietly make *moving a card is the act of execution* false —
/// and it would do it from the footer of the screen whose Start button already
/// spawns up to eight of them.
///
/// ⚠️ **A fix names its repository by id and re-resolves it when it runs.** It
/// carries a name for its own label and deliberately not a `Repo`: the value is
/// built while a `body` is evaluated and pressed some time later, and a whole
/// row captured before the press is exactly the hazard `AppModel.setRunTerms`
/// re-reads the store to avoid, one screen over on the same model.
enum AnalysisFix: Equatable, Identifiable {

    /// Point the board at this repository, which is what the panel follows while
    /// it is still a setup form (``AppModel/analysisRepoID``).
    case analyse(repoID: UUID, name: String)

    /// Switch it back on.
    ///
    /// Through ``AppModel/setRepoEnabled(_:enabled:)``, which is the writer
    /// Preflight's own *Enabled* toggle uses — the analysis panel has only ever
    /// read a `Repo`, and a screen that starts writing one needs the existing
    /// path rather than a second one beside it.
    case enable(repoID: UUID, name: String)

    /// Take the reader to the check that is failing.
    ///
    /// ✅ **Reused, not reinvented — this act already existed.** #353 built it
    /// for a card's badge: ``BlockedBadge`` names the failing check and
    /// ``AppModel/openPreflight(_:)`` performs the three parts that are a no-op
    /// without each other — unfold the console, aim it at the repository, open
    /// that check's disclosure. A second route would be a second thing to keep
    /// in agreement with Preflight's disclosure map, whose key is composite
    /// precisely because getting it wrong looks like working code
    /// (``CheckAddress``).
    ///
    /// It also carries the *right* wording for free: `BlockedBadge.openHint`
    /// exists so a tooltip and a VoiceOver label cannot name one act two ways,
    /// and this button is a third reader of the same string.
    case showPreflight(BlockedBadge)

    /// The button's text.
    ///
    /// Named on the value rather than in the view, for the reason `RepoFix.label`
    /// and `CheckFix.label` both give: two screens must not spell one act two
    /// ways. Each names its subject, because the refusal above it does not always
    /// — *"Pick a single repository to analyse."* says nothing about which.
    var label: String {
        switch self {
        case .analyse(_, let name): "Analyse \(name)"
        case .enable(_, let name): "Switch \(name) on"
        case .showPreflight(let badge): badge.openHint
        }
    }

    /// Stable across a re-render, so `ForEach` does not rebuild the row the
    /// pointer is over. Keyed on what the fix *acts on*, never on its position
    /// in the list: the repositories are a live array and one being forgotten
    /// must not renumber the rest.
    var id: String {
        switch self {
        case .analyse(let repoID, _): "analyse:\(repoID)"
        case .enable(let repoID, _): "enable:\(repoID)"
        case .showPreflight(let badge): "preflight:\(badge.repoID):\(badge.check?.id ?? "")"
        }
    }

    /// Whether this fix is one of several repositories being offered, rather than
    /// a single act.
    private var isRepositoryChoice: Bool {
        if case .analyse = self { return true }
        return false
    }

    /// The title of the menu several fixes collapse into, or `nil` when each of
    /// them is its own button.
    ///
    /// ⚠️ **It asks what the fixes *are*, not merely how many there are.** Only
    /// the repository offer is ever plural — one `.analyse` per registered
    /// repository — and eight *Analyse …* buttons across a footer measured in
    /// two board columns is not a choice, it is a wall. A plural list of anything
    /// else is a list of different acts and must stay a list of buttons; counting
    /// alone would sweep those into a menu titled for repositories.
    ///
    /// Decided here rather than in the view because it is a decision, and
    /// `swift test` cannot enter a `body` — the whole reason
    /// ``AnalysisFooterMessage`` exists at all.
    static func chooser(for fixes: [AnalysisFix]) -> String? {
        guard fixes.count > 1, fixes.allSatisfy(\.isRepositoryChoice) else { return nil }
        return "Pick a repository"
    }
}

/// Why an analysis cannot start right now — **and what to do about it**.
///
/// One value rather than a sentence beside an enum beside a repository id: the
/// remedy is only correct *because* of the sentence it sits under, and the two
/// are decided in one pass over the same three inputs. A caller that could
/// render one without the other is a footer offering *Switch off on* beside
/// *A Preflight check is failing*, which is what two independent expressions
/// would eventually produce — the shape `CardOutcome` was introduced for one
/// layer down, where the fields and the move they imply now travel together.
///
/// ⚠️ **The three sentences are the ones that shipped, verbatim.** They are
/// asserted literally by `AnalysisSessionTests`, they are what the toolbar's
/// tooltip has always said, and this change is about what the reader can *press*
/// — rewording them at the same time would make an unrelated regression look
/// like part of it.
///
/// It lives in `ElliotAppKit` beside ``AnalysisFooterMessage`` on the #72 rule:
/// put a rule in `ElliotModel` because it is pure **and shared with the MCP
/// helper**. This one is not shared — the helper has no footer, and it names
/// `BlockedBadge`, which is this module's.
///
/// The file is called `Analysis…` deliberately: that is what puts it inside
/// `AnalysisPanelViewSourceTests`'s sweep, so the rule that no analysis screen
/// resolves its subject from the board's toolbar picker covers this decision on
/// the day it was written rather than the day someone remembers.
struct AnalysisRefusal: Equatable {

    /// The sentence the footer shows and the toolbar button's tooltip repeats.
    let text: String

    /// What the reader can do about it, in the order they should meet it.
    ///
    /// Empty is a real answer and not a defensive one: with no repository
    /// registered at all there is nothing to point the board at, and a menu with
    /// no rows is the trap #151 removed from the Analyse toggle — *a control you
    /// cannot use is worse than one that opens onto an explanation*. The
    /// explanation is `text`, and it stands alone.
    let fixes: [AnalysisFix]

    init(text: String, fixes: [AnalysisFix] = []) {
        self.text = text
        self.fixes = fixes
    }

    /// The whole decision, in the order that shipped.
    ///
    /// ⚠️ **`subject` is already resolved against the registered rows**, so
    /// "nobody has picked" and "the pick names a repository that has since been
    /// forgotten" arrive here as one case — which is what
    /// `AppModel.analysisRefusal` has always done, its `guard` failing on either
    /// half. They are one case for the reader too: in both, the answer is to
    /// name a repository that exists.
    ///
    /// ⛔ **The disabled check comes before the blocked one, and the order is
    /// load-bearing.** A repository can be both, and switching a repository on
    /// is a switch the reader threw — `Consequence.reason` keeps `.repoDisabled`
    /// and `.repoBlocked` apart in as many words for this reason. Offering
    /// *Show … in Preflight* first would send someone to look for a diagnosis
    /// when the answer is a toggle they turned off themselves.
    ///
    /// `blocked` is passed in rather than computed here so this stays a function
    /// of values: `AppModel.blockedBadge(for:)` reads the persisted verdict *and*
    /// the in-memory sweep, and re-deriving either would be the second opinion
    /// that method's own doc comment refuses to be.
    ///
    /// The offer for an unpicked board is **every** registered repository, in the
    /// board's own order — including ones that are switched off or failing
    /// Preflight. Filtering them would hide from this menu repositories the
    /// toolbar's picker shows; picking one simply moves the reader to the next
    /// refusal, which names the next thing to press.
    static func decide(
        subject: Repo?, registered: [Repo], blocked: BlockedBadge?
    ) -> AnalysisRefusal? {
        guard let subject else {
            return AnalysisRefusal(
                text: "Pick a single repository to analyse.",
                fixes: registered.map { .analyse(repoID: $0.id, name: $0.displayName) })
        }
        if !subject.isEnabled {
            return AnalysisRefusal(
                text: Consequence.reason(.repoDisabled),
                fixes: [.enable(repoID: subject.id, name: subject.displayName)])
        }
        if let blocked {
            return AnalysisRefusal(
                text: "A Preflight check is failing for this repository — fix it there first.",
                fixes: [.showPreflight(blocked)])
        }
        return nil
    }
}
