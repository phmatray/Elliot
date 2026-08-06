import ElliotModel
import SwiftUI

struct CardView: View {
    @Environment(AppModel.self) private var model
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.displayTitle)
                .font(Type.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                RunningStrip(run: run, lastLine: lastLine(of: run))
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
                .transition(.opacity)
            }

            if !facts.isEmpty || repoName != nil || stagnation != nil {
                HStack(spacing: 5) {
                    ForEach(facts, id: \.text) { fact in
                        LinkBadge(text: fact.text, systemImage: fact.icon, url: fact.url)
                    }
                    Spacer(minLength: 0)
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

            if isBlockedRepo {
                Label("Repository blocked — see Preflight", systemImage: "exclamationmark.triangle.fill")
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
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
        .contextMenu { menu }
        .task(id: card.id) { await model.refreshRuns(cardID: card.id) }
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

    /// The most recent event of this run that says anything in one line.
    ///
    /// Searched backwards rather than taken from the end: `liveLog` holds every
    /// event now, and most of them — a successful tool result, a `system` line,
    /// a partial — collapse to nothing. Taking the last event outright would
    /// blank the strip every time one of those arrived last.
    private func lastLine(of run: SkillRun) -> String? {
        guard let events = model.liveLog[run.id] else { return nil }
        return events.reversed().lazy.compactMap(AppModel.describe).first
    }

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

    private var isBlockedRepo: Bool {
        model.repo(for: card).map { model.isBlocked($0) } == true
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

/// A run in flight, on the card. Says how long it has been going and what it
/// last did — a bare spinner cannot distinguish a healthy ten-minute run from a
/// wedged one.
struct RunningStrip: View {
    let run: SkillRun
    let lastLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // Queued, running and cancelling used to share one spinner, so
                // pressing Cancel changed nothing on screen. A spinner means
                // output is arriving; anything else says which state it is in.
                if run.state == .running {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: run.state.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(run.state.tint)
                        .frame(width: 12, height: 12)
                }
                Text(run.kind.skillName)
                    .font(Type.fact)
                    .foregroundStyle(run.state.tint)
                if run.state != .running {
                    Text(run.state.label)
                        .font(Type.prose)
                        .foregroundStyle(run.state.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let started = run.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Fact(text: Elapsed.short(from: started, to: context.date), small: true)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let lastLine, !lastLine.isEmpty {
                Text(lastLine)
                    .font(Type.factSmall)
                    .foregroundStyle(Palette.quiet)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if run.state == .stalled {
                Text("No output for a while. It may still be thinking.")
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.wash(run.state.tint))
        .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
    }

}

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
