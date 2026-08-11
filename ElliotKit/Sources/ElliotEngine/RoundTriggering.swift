import Foundation

/// Something that wants to re-evaluate whenever Elliot's own machinery moves.
///
/// Registered explicitly and held weakly, in the shape of the `SystemMoving` the
/// scheduler and the watcher already hold — for the same cycle-breaking reason,
/// and for one more.
///
/// ⚠️ `RunScheduler.updates` is an `AsyncStream`, and an `AsyncStream` does not
/// multiplex: two `for await` loops draw from one buffer, so each event reaches
/// exactly one of them. `AppModel` owns the only iteration. A second consumer
/// would split the events between the board's UI and this, silently and
/// non-deterministically, with everything green.
///
/// An implementation must be **idempotent and cheap to call twice**: several
/// events arrive per finished run, and nothing here promises a call per event.
public protocol RoundTriggering: AnyObject, Sendable {
    func triggerRound() async
}
