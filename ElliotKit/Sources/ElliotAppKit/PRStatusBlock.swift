import ElliotModel
import SwiftUI

/// What GitHub last said about this card's pull request, as three facets and a
/// provenance line.
///
/// The card carries one mark because that is all it has room for. Here there is
/// room for the picture, and the picture is the point: a pull request can be
/// green **and** in conflict, and a headline that collapsed the two would hide
/// the half that is actually blocking it.
///
/// Nothing is drawn when Elliot has not read this pull request. An empty block
/// saying "CI —" for a card nobody looked at is an all-clear nobody established,
/// which is the false green the whole feature exists to avoid.
struct PRStatusBlock: View {
    @Environment(AppModel.self) private var model
    let card: Card

    var body: some View {
        if let resolved = model.prStatus(for: card) {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "Pull request")

                if let sign = resolved.sign {
                    Label {
                        Text(sign.summary).font(Type.prose)
                    } icon: {
                        Image(systemName: sign.icon).font(.system(size: 11))
                    }
                    .foregroundStyle(sign.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                }

                facet("CI", ciText(resolved.ci), tint: ciTint(resolved.ci))
                facet("Merge", mergeText(resolved.merge), tint: mergeTint(resolved.merge))
                facet("Review", reviewText(resolved.review), tint: .secondary)

                if !resolved.isStale, !checks.isEmpty {
                    // The names, not a verdict about them. Elliot deliberately
                    // does not decide that `CodeQL` or `renovate/stability-days`
                    // is not a build — that judgement's data lives in
                    // `repo-audit`, and a second copy here would drift. Printing
                    // what ran lets the reader see it for themselves.
                    checkList
                }

                provenance(resolved)
            }
        }
    }

    // MARK: - Pieces

    private var checks: [GHMergeStatus.StatusCheck] {
        model.prStatuses[card.id]?.checks ?? []
    }

    private var checkList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 6) {
                    Image(systemName: checkIcon(check))
                        .font(.system(size: 9))
                        .foregroundStyle(checkTint(check))
                    Text(check.label)
                        .font(Type.factSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 92)
    }

    private func facet(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Fact(text: value, tint: tint)
            Spacer(minLength: 0)
        }
    }

    /// When it was read and on what — the same discipline as the verdict block:
    /// a fact is worth what its provenance is worth.
    private func provenance(_ resolved: ResolvedPRStatus) -> some View {
        Text(provenanceText(resolved))
            .font(Type.factSmall)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private func provenanceText(_ resolved: ResolvedPRStatus) -> String {
        let sha = String(resolved.headRefOid.prefix(7))
        let age = Elapsed.age(of: resolved.checkedAt)
        guard !resolved.isStale else {
            return "Read \(age) on \(sha) — too old, or about a commit that is no longer the head."
        }
        return "Read \(age) · \(sha)"
    }

    // MARK: - Wording

    private func ciText(_ state: CIState) -> String {
        switch state {
        case .noChecks: "no check has run"
        case .running: "running"
        case .passing(let count): count == 1 ? "1 check passed" : "\(count) checks passed"
        case .failing(let names): names.joined(separator: ", ")
        case .unknown: "not established"
        }
    }

    private func ciTint(_ state: CIState) -> Color {
        switch state {
        case .noChecks: Palette.attention
        case .running: Palette.inert
        case .passing: Palette.verified
        case .failing: Palette.refused
        case .unknown: Palette.quiet
        }
    }

    private func mergeText(_ state: MergeState) -> String {
        switch state {
        case .clean: "no conflict"
        case .conflict: "in conflict with the base branch"
        case .blocked: "blocked by a rule"
        case .behind: "behind the base branch"
        // GitHub files *pending* under UNSTABLE as well as failing — measured on
        // this feature's own pull request, whose only check was QUEUED. "A check
        // is unhappy" read as a failure that had not happened. The CI facet
        // directly above already says which of the two it is.
        case .unstable: "mergeable, not every check is green"
        case .unknown: "not established"
        }
    }

    private func mergeTint(_ state: MergeState) -> Color {
        switch state {
        case .clean: Palette.verified
        case .conflict: Palette.refused
        case .blocked, .behind, .unstable: Palette.attention
        case .unknown: Palette.quiet
        }
    }

    /// `.none` reads as a plain statement, never as a warning. On a solo
    /// repository nothing is ever reviewed, and dressing that as a problem would
    /// light up every card for ever.
    private func reviewText(_ state: ReviewState) -> String {
        switch state {
        case .none: "nobody has reviewed"
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .reviewRequired: "a review is required"
        case .unknown: "not established"
        }
    }

    private func checkIcon(_ check: GHMergeStatus.StatusCheck) -> String {
        if check.hasFailed { return "xmark.circle.fill" }
        if check.isPending { return "clock" }
        return "checkmark.circle.fill"
    }

    private func checkTint(_ check: GHMergeStatus.StatusCheck) -> Color {
        if check.hasFailed { return Palette.refused }
        if check.isPending { return Palette.inert }
        return Palette.verified
    }
}
