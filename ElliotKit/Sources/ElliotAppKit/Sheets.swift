import ElliotModel
import SwiftUI

/// Confirming the one irreversible act in the product.
///
/// This was `FollowUpSheet`, a fixed 540×440 sheet over the board. It hid
/// exactly what is needed to decide — whether another run is already going in
/// the same repository, and what else is queued — at the one moment that
/// matters. Three screens had already left their sheets for that reason
/// (see `ElliotApp.swift`); two were left behind.
///
/// It renders in the details panel, which is already the card's detail and
/// already beside the board. `AppModel` selects the card and opens the panel
/// *before* setting `pendingFollowUps`, because the panel only draws for a
/// selected card — this is the one change here that could fail **closed**, and
/// a merge with nowhere to confirm it is a merge you cannot do.
struct MergeConfirmation: View {
    @Environment(AppModel.self) private var model

    let pending: AppModel.PendingMerge
    @State private var items: [String] = [""]

    /// The PR number as a plain string.
    ///
    /// ⚠️ Not interpolated into a `Text` or a `Button` title directly. Those take
    /// a `LocalizedStringKey`, which formats an interpolated `Int` for the
    /// reader's locale — so PR 1234 rendered as **"Merge PR 1.234"** on a
    /// European machine. A pull request number is an identifier, not a quantity,
    /// and it must never be group-separated. Found by looking at the screen: the
    /// button underneath said "merges PR 1234" correctly, because that sentence
    /// is built as a `String`, and the two contradicted each other.
    private var pr: String { String(pending.prNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").foregroundStyle(Palette.irreversible)
                    Text("Merge pull request \(pr)").font(Type.rowTitle)
                }
                Text("This merges into the repository's default branch on github.com and cannot be undone from Elliot.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FollowUpList(items: $items)

            Text(followUpSentence)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { model.cancelPendingMerge() }
                Spacer()
                Button("Merge PR \(pr)") {
                    Task {
                        await model.confirmMerge(
                            cardID: pending.cardID, followUps: cleaned, origin: pending.origin)
                    }
                }
                // ⛔ No `.keyboardShortcut(.defaultAction)`, and its absence is
                // load-bearing — see `DefaultAction`, which lists this control
                // among the ones deliberately denied one.
                //
                // It carried one until it was measured against the panel it
                // actually renders in. `PanelLayout.headerRegions` returns
                // `[.mergeConfirmation]` and only *then* checks `isEditing`, so
                // this confirmation deliberately survives edit mode; on a card
                // imported from a pull request that closes no issue —
                // `issueNumber == nil`, so "Edit story" shows; `prNumber != nil`,
                // so a merge can be armed — Return had two claimants on screen
                // at once and resolved between saving an edit and merging to a
                // default branch on github.com, with nothing in the code
                // deciding.
                //
                // The fix is not to scope Return better. The one act in this
                // product that cannot be taken back must be reached by pressing
                // it, which is the same argument `AnalysisPanelView` makes for
                // its Start button one panel over.
                .tint(Palette.irreversible)
            }
        }
        .padding(10)
        .background(Surface.wash(Palette.irreversible))
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .strokeBorder(Surface.washBorder(Palette.irreversible), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm merging pull request \(pr)")
    }

    /// Restates the ordering the section above promises: the issues are filed
    /// *after* the merge lands, not instead of it.
    private var followUpSentence: String {
        switch cleaned.count {
        case 0: "No follow-ups will be filed."
        case 1: "1 issue will be filed after the merge."
        default: "\(cleaned.count) issues will be filed after the merge."
        }
    }

    private var cleaned: [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The follow-up lines, extracted so their wording lives once rather than being
/// copied into whichever view happens to need them next.
struct FollowUpList: View {
    @Binding var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConsoleLabel(text: "Follow-ups")
            Text("Each line becomes a new issue after the merge lands. Leave it empty if there are none.")
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(
                        "What still needs doing…",
                        text: Binding(
                            get: { items.indices.contains(index) ? items[index] : "" },
                            set: { if items.indices.contains(index) { items[index] = $0 } }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Button {
                        items.remove(at: index)
                        if items.isEmpty { items = [""] }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove follow-up \(index + 1)")
                }
            }
            Button("Add another", systemImage: "plus") { items.append("") }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}
