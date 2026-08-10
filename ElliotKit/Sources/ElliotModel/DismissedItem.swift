import Foundation

/// One suppression, as the reader sees it: ``ExternalRef`` is the key, and this
/// is that key carrying the fact the key threw away.
///
/// Deleting a card that holds an issue or a pull request writes a row per number
/// — `BoardService.deleteCard` — and `GitHubImporter.plan` then skips that unit
/// on every refresh, for ever. That is the right behaviour and it was
/// **write-only**: `BoardStore.dismissals` maps the table down to a
/// `Set<ExternalRef>` because its one caller is the importer, which needs only
/// the keys, so the date the row was written has been stored since v5 and read
/// by nobody. A reader who dismissed nine correctly and one by mistake could
/// only forget all ten.
public struct DismissedItem: Codable, Sendable, Hashable, Identifiable {
    public var repoID: UUID
    public var ref: ExternalRef
    public var dismissedAt: Date

    public init(repoID: UUID, ref: ExternalRef, dismissedAt: Date) {
        self.repoID = repoID
        self.ref = ref
        self.dismissedAt = dismissedAt
    }

    /// The row's primary key, spelled — `(repo, kind, number)`, which is what
    /// `dismissedExternal` is keyed on and what ``BoardStore/undismiss(_:repoID:)``
    /// deletes by.
    ///
    /// Deliberately **not** the date, and deliberately not an array index. A
    /// card carrying both an issue and its pull request writes two rows with the
    /// same number and the same timestamp; keyed on either, `ForEach` would draw
    /// one row for two suppressions and *Restore* would act on whichever it
    /// happened to resolve.
    public var id: String { "\(repoID.uuidString)|\(ref.kind.rawValue)|\(ref.number)" }
}

/// One repository's suppressions, ready to draw as a section.
///
/// A named type rather than the `(repoID:rows:)` tuple the issue sketched: a
/// tuple array is neither `Identifiable` — so every `ForEach` over it invents
/// its own `id:` — nor `Equatable`, so a test can only compare it field by
/// field. Both of those are how two call sites end up disagreeing about what a
/// group is.
public struct DismissalGroup: Sendable, Hashable, Identifiable {
    public var repoID: UUID
    public var rows: [DismissedItem]

    public init(repoID: UUID, rows: [DismissedItem]) {
        self.repoID = repoID
        self.rows = rows
    }

    public var id: UUID { repoID }
}

extension ExternalRef {
    /// `"Issue #4"` · `"PR #1234"`.
    ///
    /// ⚠️ **Built with `String(number)`, and never interpolated into a `Text` or
    /// a `Button` title directly.** Those take a `LocalizedStringKey`, which
    /// formats an interpolated `Int` for the reader's locale — that is how PR
    /// 1234 rendered as *"Merge PR 1.234"* on a European machine
    /// (`MergeConfirmation`, `Sheets.swift`). A ref's number is an identifier,
    /// not a quantity, and it must never be group-separated. Passing this
    /// property — a `String` variable, not a literal — is what makes the
    /// verbatim `Text` overload the one that wins.
    public var label: String {
        switch kind {
        case .issue: "Issue #" + String(number)
        case .pullRequest: "PR #" + String(number)
        }
    }
}

/// What the dismissal list says, and in what order.
///
/// Pure, and with **no clock**: `dismissedAt` is rendered by the view with
/// `formatted(date:time:)`, which is what every other date in this app does and
/// what keeps a `DateFormatter` out of `ElliotModel`.
public enum DismissalDigest {

    /// The rows for the repositories in view, newest first.
    ///
    /// `repoID: nil` is *All repositories* — the same meaning
    /// `AppModel.selectedRepoID` has everywhere else — not "no filter has been
    /// decided yet". A repository id that matches nothing yields an empty list,
    /// which is the honest answer: collapsing an unknown id into "no filter" is
    /// what once made a typo return the whole board as a success.
    ///
    /// ⚠️ **The order is total, not merely descending.** `deleteCard` dismisses
    /// every number a card holds inside one act, so a card carrying an issue and
    /// its pull request writes two rows whose `dismissedAt` can be equal to the
    /// millisecond. Sorted on the date alone, those two would be free to swap
    /// places between two reads of an unchanged table — a list that reshuffles
    /// under the pointer, next to a *Restore* button.
    public static func rows(_ items: [DismissedItem], repoID: UUID?) -> [DismissedItem] {
        let scoped = repoID.map { id in items.filter { $0.repoID == id } } ?? items
        return scoped.sorted { left, right in
            if left.dismissedAt != right.dismissedAt { return left.dismissedAt > right.dismissedAt }
            if left.ref.kind != right.ref.kind { return left.ref.kind.rawValue < right.ref.kind.rawValue }
            return left.ref.number < right.ref.number
        }
    }

    /// The same rows, split per repository, each group already ordered.
    ///
    /// Groups are ordered by their own newest row, so the repository something
    /// was just dismissed in is the one at the top — and tied groups fall back
    /// to the repository id for the reason the row tie-break exists: two
    /// sections that swap places between reads is the same defect one level up.
    ///
    /// The group carries an id and not a name. Naming a repository needs
    /// `Repo.displayName`, which is a row in the store; this type is pure, and
    /// the view already holds the list it would look the name up in.
    public static func groups(_ items: [DismissedItem], repoID: UUID?) -> [DismissalGroup] {
        let ordered = rows(items, repoID: repoID)
        var byRepo: [UUID: [DismissedItem]] = [:]
        for item in ordered { byRepo[item.repoID, default: []].append(item) }
        return byRepo
            .map { DismissalGroup(repoID: $0.key, rows: $0.value) }
            .sorted { left, right in
                let leftNewest = left.rows.first?.dismissedAt ?? .distantPast
                let rightNewest = right.rows.first?.dismissedAt ?? .distantPast
                if leftNewest != rightNewest { return leftNewest > rightNewest }
                return left.repoID.uuidString < right.repoID.uuidString
            }
    }

    /// `"3 dismissed"`, or `nil` when there is nothing to say.
    ///
    /// Absent at zero rather than reading `"0 dismissed"`, following the queue
    /// and the artefact sweep: a permanent zero in the status bar is furniture,
    /// and that strip has been pushed around by its own contents before. The
    /// face stays reachable at zero through the View menu, which is what keeps
    /// `ConsoleReachabilityTests` honest rather than accidentally satisfied.
    ///
    /// A count is a genuine quantity, so group-separating it would not be the
    /// `MergeConfirmation` defect — but it is built without a locale anyway,
    /// because a figure that reads differently in Brussels than in London is a
    /// figure two bug reports disagree about.
    public static func figure(count: Int) -> String? {
        guard count > 0 else { return nil }
        return String(count) + " dismissed"
    }
}
