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

            if let story = card.story, activeRun == nil {
                Text(story.narrative)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let run = activeRun {
                RunningStrip(run: run, lastLine: model.liveLog[run.id]?.last)
            } else if let receipt = lastReceipt {
                // What `gh` established, not what the agent said about itself.
                Label {
                    Text(receipt.text).font(Type.fact)
                } icon: {
                    Image(systemName: receipt.icon).font(.system(size: 10))
                }
                .foregroundStyle(receipt.tint)
                .lineLimit(1)
            }

            if !facts.isEmpty || repoName != nil {
                HStack(spacing: 5) {
                    ForEach(facts, id: \.text) { fact in
                        LinkBadge(text: fact.text, systemImage: fact.icon, url: fact.url)
                    }
                    Spacer(minLength: 0)
                    if let repoName {
                        Fact(text: repoName, small: true)
                            .foregroundStyle(.tertiary)
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
        // Carrying the button trait without an action makes the card look
        // operable to assistive technology and do nothing when operated. The
        // tap gesture is invisible to it; this is the same act, exposed.
        .accessibilityAction { toggleSelection() }
        .contextMenu { menu }
        .task(id: card.id) { await model.refreshRuns(cardID: card.id) }
    }

    @ViewBuilder
    private var menu: some View {
        if let run = activeRun {
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

    private var isBlockedRepo: Bool {
        model.repo(for: card).map { model.isBlocked($0) } == true
    }

    /// The verdict of the most recent finished run.
    private var lastReceipt: (text: String, tint: Color, icon: String)? {
        model.runsByCard[card.id]?
            .first { $0.state.isTerminal && $0.verifiedOutcome != nil }?
            .verifiedOutcome?
            .receipt
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
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                Text(run.kind.label)
                    .font(Type.fact)
                    .foregroundStyle(run.state.tint)
                Spacer(minLength: 0)
                if let started = run.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Fact(text: elapsed(from: started, to: context.date), small: true)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let lastLine, !lastLine.isEmpty {
                Text(lastLine)
                    .font(Type.factSmall)
                    .foregroundStyle(.tertiary)
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
        .background(run.state.tint.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60
            ? "\(seconds)s"
            : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
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
            .background(Color.secondary.opacity(hovering && url != nil ? 0.22 : 0.12))
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
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(Palette.refused)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.refused.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
