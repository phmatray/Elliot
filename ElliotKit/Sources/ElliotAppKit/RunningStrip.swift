import ElliotModel
import SwiftUI

/// A run in flight. Says how long it has been going and what it last did — a
/// bare spinner cannot distinguish a healthy ten-minute run from a wedged one.
///
/// It lives in its own file because it is drawn in two places: on the card whose
/// run it is, and in Operations' *Running now* band, which is the only surface
/// that shows an **analysis** run at all (`activeRuns` is keyed by card id and an
/// analysis has no card). This repository has paid for the same mechanism
/// written twice more than once — `ChildProcess`/#146 is the standing example —
/// so the second reader takes this component rather than a copy of it.
///
/// The two places differ in what they can leave unsaid, which is what `context`
/// and `cancel` are: a card already names its repository and offers Cancel in
/// its context menu, and a band listing every repository's runs can assume
/// neither. Both default to nothing, so the card's rendering is what it was.
struct RunningStrip: View {
    let run: SkillRun
    let lastLine: String?

    /// What this run is about — the repository, and the lens when it has one.
    ///
    /// `nil` on a card, which is already the run's context. Built by
    /// `SkillRun.context(repoName:)` so the one place that needs it does not
    /// invent a second wording.
    var context: String? = nil

    /// Stopping this run, when the surface offers that.
    ///
    /// ⛔ The **strip** decides whether to draw it, not the caller: a Cancel on a
    /// run that has already had its SIGTERM is a button that does nothing, and a
    /// gate written at each call site is a gate one call site will forget.
    /// `RunState.isCancellable` is that rule and it is asked here.
    ///
    /// Whatever is passed must reach `AppModel.cancelRun` — one funnel. A second
    /// path that stopped a process without the scheduler knowing is exactly the
    /// state the board cannot recover from.
    var cancel: (() -> Void)? = nil

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
                if let context {
                    Fact(text: context, tint: Palette.quiet, small: true)
                        .lineLimit(1)
                }
                if run.state != .running {
                    Text(run.state.label)
                        .font(Type.prose)
                        .foregroundStyle(run.state.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let started = run.startedAt {
                    // `tick`, not `context`: the strip now has a property of
                    // that name, and a shadowed one reads as the same thing.
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        Fact(text: Elapsed.short(from: started, to: tick.date), small: true)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let cancel, run.state.isCancellable {
                    Button("Cancel", action: cancel)
                        .controlSize(.small)
                        // The band lists several runs, so "Cancel" alone names
                        // none of them to a screen reader.
                        .accessibilityLabel("Cancel \(run.kind.skillName)")
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
