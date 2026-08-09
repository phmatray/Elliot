import ElliotModel
import SwiftUI

struct CardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Symbol then name, the order the Analysis window already uses in
            // all three of its sites — the lens tile, the run row and the
            // section header. `.firstTextBaseline` so a title that wraps to two
            // lines sits under itself rather than under the emoji.
            //
            // Nothing is drawn when there is no lens, and no gutter is reserved
            // for one: a card written by hand was not found through a lens, and
            // a placeholder meaning "no lens" reads as a mark meaning something.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let angle = card.angle {
                    Text(angle.symbol)
                        .font(Type.cardTitle)
                        // The card is one combined accessibility element, so an
                        // unlabelled emoji is read as whatever the system calls
                        // the character, jammed against the title. The lens has
                        // a name.
                        .accessibilityLabel(angle.title)
                        .help(angle.title)
                }
                Text(card.displayTitle)
                    .font(Type.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The benefit, not the narrative. The label above already restates
            // the want clause, so the narrative spent both of these lines
            // re-reading the title through 23 fixed characters of "As a
            // developer, I want …" and truncated away the only clause nothing
            // else on the card carries.
            if let story = card.story, activeRun == nil, !story.cardSummary.isEmpty {
                Text(story.cardSummary)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let run = activeRun {
                // No `context:` and no `cancel:`: the card *is* the run's
                // context, and Cancel is in its menu. Operations' band passes
                // both — one component, two surfaces.
                RunningStrip(run: run, lastLine: model.lastLine(of: run))
            } else if let receipt = lastReceipt {
                // What `gh` established, not what the agent said about itself.
                HStack(spacing: 5) {
                    Label {
                        Text(receipt.text).font(Type.fact)
                    } icon: {
                        Image(systemName: receipt.icon).font(.system(size: 10))
                    }
                    .foregroundStyle(receipt.tint)
                    .lineLimit(1)
                    // A receipt with no time cannot be told from one produced a
                    // week ago.
                    if let ended = lastReceiptEndedAt {
                        Fact(text: Elapsed.age(of: ended), tint: Palette.quiet, small: true)
                    }
                }
                // Gated here rather than left to an ancestor, and that is not
                // belt-and-braces. The two gated animations this view sits
                // under are keyed on `selectedCardID` and on `cards.map(\.id)`;
                // a receipt appears when a *run finishes*, which changes
                // neither. Nothing above answers for this one, so it says so
                // itself. `.identity` is what a transition looks like with
                // reduce motion on: the row is simply there.
                .transition(reduceMotion ? .identity : .opacity)
            }

            if !facts.isEmpty || repoName != nil || stagnation != nil || prSign != nil {
                HStack(spacing: 5) {
                    ForEach(facts, id: \.text) { fact in
                        LinkBadge(text: fact.text, systemImage: fact.icon, url: fact.url)
                    }
                    Spacer(minLength: 0)
                    // What is holding this card's pull request up, when anything
                    // is. One mark, the most blocking known fact — the panel
                    // shows the three facets apart. Nothing is drawn when there
                    // is nothing to report, and nothing is drawn for a card
                    // nobody has read: an all-clear nobody established would be
                    // the false green this whole feature exists to avoid.
                    //
                    // Same shape as the age badge beside it rather than a new
                    // container: every window this project has broken was broken
                    // by new structure.
                    if let prSign {
                        Image(systemName: prSign.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(prSign.tint)
                            .accessibilityLabel(prSign.summary)
                            .help(prSign.summary)
                    }
                    // Not in `facts`: every element of that array renders as a
                    // `LinkBadge` button, and an age is not a link.
                    if let stagnation {
                        Fact(text: stagnation.shortLabel, tint: Palette.quiet, small: true)
                            .help("In \(card.column.displayName) for \(stagnation.days) days")
                    }
                    if let repoName {
                        Fact(text: repoName, tint: Palette.quiet, small: true)
                            .lineLimit(1)
                    }
                }
            }

            // Names the check that refused this card, and goes there.
            //
            // A real `Button`, like `LinkBadge` above it, rather than a tap
            // gesture on the label: a gesture here would be a second claimant on
            // the card's own tap, which is the ancestor/descendant problem this
            // board has already paid for four times.
            //
            // `lineLimit(1)` because a check title is not this file's to bound —
            // it comes from `PreflightService` — and a card is a narrow surface
            // whose height is shared with the columns either side of it. A long
            // title truncates; it does not reflow the card.
            if let badge = blockedBadge {
                Button {
                    model.openPreflight(badge)
                } label: {
                    Label(badge.sentence, systemImage: "exclamationmark.triangle.fill")
                        .font(Type.prose)
                        .foregroundStyle(Palette.attention)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(badge.openHint)
            }

            if let refusal = model.refusal, refusal.cardID == card.id {
                RefusalNote(message: refusal.message) { model.dismissRefusal() }
            } else if let error = card.lastError {
                Text(error)
                    .font(Type.prose)
                    .foregroundStyle(Palette.refused)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .strokeBorder(
                    isSelected ? Palette.armed : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Select to see what each column would do with this card.")
        // `RefusalNote` renders inside an element `.combine` has already been
        // passed, so the reason a gesture did nothing was drawn on the card and
        // unreachable from it.
        .accessibilityValue(refusalMessage ?? "")
        // Carrying the button trait without an action makes the card look
        // operable to assistive technology and do nothing when operated. The
        // tap gesture is invisible to it; this is the same act, exposed.
        .accessibilityAction { toggleSelection() }
        // The badge's button is inside an element `.combine` has already
        // flattened, so assistive technology can read the sentence and cannot
        // press it — the same gap the default action above exists to close, for
        // the same reason. Offered only when there is one, because an action
        // that resolves to nothing is the confident-looking no-op this file
        // keeps refusing to ship.
        .accessibilityActions {
            if let badge = blockedBadge {
                Button(badge.openHint) { model.openPreflight(badge) }
            }
        }
        .contextMenu { menu }
        .task(id: card.id) { await model.refreshRuns(cardID: card.id) }
        // Where the caret points. A card's y inside a `LazyVStack` inside a
        // scrolling column genuinely cannot be computed — it has to be measured
        // — and this is the measurement.
        //
        // An anchor rather than a `GeometryReader`: a reader wrapped around a
        // card would take all the space offered and change the card's own
        // layout, and one in a background would answer in a later update than
        // the layout that moved the card. A preference writer changes no
        // geometry at all, and the rect it carries is resolved by whoever reads
        // it — so the card, its column's viewport and the panel are measured in
        // one space, with nothing to keep in sync.
        //
        // Only the selected card contributes. Every other card writes the empty
        // value, which `CaretAnchorKey.reduce` merges away.
        //
        // Through `reportsCaretAnchor` rather than a bare `.anchorPreference`:
        // this card has children, so the same ancestor-replaces-subtree rule
        // that cost #159 applies here the moment anything below reports an
        // anchor. The helper is the one supported way to write this key.
        .reportsCaretAnchor { bounds in
            isSelected ? CaretAnchors(card: bounds) : CaretAnchors()
        }
    }

    @ViewBuilder
    private var menu: some View {
        // Not merely `activeRun`: a run already cancelling has had its
        // SIGTERM, so a second Cancel is a button that does nothing.
        if let run = activeRun, run.state.isCancellable {
            Button("Cancel run", systemImage: "stop.circle") {
                Task { await model.cancelRun(id: run.id) }
            }
            Divider()
        }
        if let url = card.issueURL {
            Button("Open issue on GitHub", systemImage: "safari") { open(url) }
        }
        if let url = card.prURL {
            Button("Open pull request on GitHub", systemImage: "safari") { open(url) }
        }
        if card.issueURL != nil || card.prURL != nil { Divider() }
        Button("Delete card", systemImage: "trash", role: .destructive) {
            Task { await model.deleteCard(id: card.id) }
        }
    }

    private func toggleSelection() {
        model.selectedCardID = isSelected ? nil : card.id
    }

    private var isSelected: Bool { model.selectedCardID == card.id }
    private var activeRun: SkillRun? { model.activeRuns[card.id] }

    private var refusalMessage: String? {
        model.refusal?.cardID == card.id ? model.refusal?.message : nil
    }

    /// How long this card has sat where it is, when that says anything.
    ///
    /// Suppressed while a run is in flight — `RunningStrip` owns the clock
    /// then, and two elapsed times on one card read as one contradicting the
    /// other. `Date.now` is read during `body`, so this refreshes on the next
    /// render rather than on a timer; at day granularity that is enough, and it
    /// is the reason not to state this in minutes.
    private var stagnation: Stagnation? {
        guard activeRun == nil else { return nil }
        return card.stagnation(now: .now)
    }

    /// Why this card cannot move, when it cannot — the sentence and the
    /// destination in one value, decided by `AppModel` against the same verdict
    /// the drop is decided by.
    private var blockedBadge: BlockedBadge? {
        model.repo(for: card).flatMap { model.blockedBadge(for: $0) }
    }

    /// The one mark the card has room for.
    ///
    /// Suppressed while a run is in flight, for the same reason `stagnation` is:
    /// the strip owns the card's attention then, and a stale conflict badge
    /// beside a live run reads as a contradiction.
    private var prSign: PRSign? {
        guard activeRun == nil else { return nil }
        return model.prStatus(for: card)?.sign
    }

    /// The verdict of the most recent finished run.
    private var lastReceipt: (text: String, tint: Color, icon: String)? {
        lastVerifiedRun?.verifiedOutcome?.receipt
    }

    /// When that verdict was reached.
    private var lastReceiptEndedAt: Date? { lastVerifiedRun?.endedAt }

    private var lastVerifiedRun: SkillRun? {
        model.runsByCard[card.id]?
            .first { $0.state.isTerminal && $0.verifiedOutcome != nil }
    }

    private struct CardFact {
        var text: String
        var icon: String
        var url: String?
    }

    /// Everything on this row was read back from `gh`, so all of it is set in
    /// the fact face.
    private var facts: [CardFact] {
        var out: [CardFact] = []
        if let issue = card.issueNumber {
            out.append(CardFact(text: "#\(issue)", icon: "circle.dashed", url: card.issueURL))
        }
        if let pr = card.prNumber {
            out.append(CardFact(text: "PR \(pr)", icon: "arrow.triangle.pull", url: card.prURL))
        }
        return out
    }

    private var repoName: String? {
        guard model.selectedRepoID == nil else { return nil }
        return model.repo(for: card)?.displayName
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Pieces

/// A fact that is also a link. A real button, so it can be reached by keyboard
/// and shows a focus ring — the previous version was a tap gesture on a capsule,
/// which opened a browser and was invisible to the keyboard.
struct LinkBadge: View {
    var text: String
    var systemImage: String
    var url: String?

    @State private var hovering = false

    var body: some View {
        Button {
            guard let url, let real = URL(string: url) else { return }
            NSWorkspace.shared.open(real)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(text).font(Type.factSmall)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(hovering && url != nil ? Surface.chipFillHover : Surface.chipFill)
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { hovering = $0 }
        .help(url == nil ? text : "Open \(text) on GitHub")
        .accessibilityLabel(url == nil ? text : "Open \(text) on GitHub")
    }
}

/// Why the last gesture did nothing, shown on the card it was refused for.
struct RefusalNote: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
            Text(message)
                .font(Type.prose)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                // An 8 pt glyph is an 8 pt target. The frame gives it a real
                // one without changing how it looks.
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(Palette.refused)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.wash(Palette.refused))
        .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
    }
}
