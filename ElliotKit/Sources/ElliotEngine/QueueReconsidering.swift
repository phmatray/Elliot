import Foundation

/// Something that is holding runs it has already refused, and can be asked to
/// decide again.
///
/// ⛔ **This exists because an admission rule can be released by a fact the
/// scheduler never hears about.** Every other refusal the queue can hold a run
/// under is released by something the scheduler itself does — a run finishing,
/// a cap raised, a ceiling raised, a resume — and each of those already ends in
/// a drain. `.mergeVerdictNotEstablished` is the first that is released from
/// *outside*: the reading behind a merge goes stale with the passage of time and
/// becomes current again only when `PRWatcher` writes a new row. Nothing in that
/// path touched the queue, so a merge held for a stale reading was refused for
/// ever, waited out its session's patience, and was cancelled — under a refusal
/// sentence promising that "the merge starts as soon as a current reading says
/// the pull request is green".
///
/// The narrow shape is deliberate: the drain belongs where the fact changed, not
/// on a timer and not at the end of a round. A poll would re-ask a question
/// whose answer only changes when a specific row is written, and a drain folded
/// into `AutoDevService.round()` would tie the release of a *scheduler* rule to
/// a session existing at all — a merge a human queued is held by the same rule.
///
/// `AnyObject` and held weakly by whoever registers one, in the shape of
/// `SystemMoving` and `RoundTriggering`: the registrant is owned by the same
/// object graph that owns the scheduler, so a strong reference back would be a
/// cycle neither could break.
///
/// An implementation must be **idempotent and cheap to call twice**. A sweep
/// that refreshed four readings asks once, and a sweep that refreshed none must
/// be free to ask anyway without that being wrong.
public protocol QueueReconsidering: AnyObject, Sendable {
    /// Re-run admission over everything pending, and start whatever now passes.
    func reconsiderQueue() async
}
