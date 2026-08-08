// Posts a real mouse click at a global screen point.
//
//     swift Scripts/realclick.swift <x> <y>
//
// ⛔ **This exists because `osascript -e 'tell application "System Events" to
// click at {x, y}'` is not a mouse click.** It resolves the accessibility
// element at that point and *presses* it — `AXPress` — so:
//
//   - a view carrying `.accessibilityAction` answers while its `.onTapGesture`
//     never runs, and
//   - a view carrying neither returns a perfectly plausible element descriptor
//     and does nothing at all.
//
// Both read exactly like "the gesture is broken". That is how #158 came to
// report a working deselect as dead, and how #152 recorded the same reading
// before it: the descriptor `scroll area 1 of scroll area 1 of group 1 of
// window Elliot` is not the column's list swallowing a click, it is the
// nearest accessibility element to a press that no view had an action for.
//
// Run through `swift` rather than compiled and committed as a binary: the
// toolchain is already a hard requirement here, so this costs a second of
// interpretation and nothing to maintain.
//
// ⚠️ Posting events needs Accessibility, held by the **responsible process** of
// whatever shell runs this — your terminal, or Elliot itself when Elliot spawned
// the agent session. So **whether your shell holds it depends on which shell you
// are**: an interactive Terminal someone ticked the box for is a different TCC
// identity from a spawned agent.
//
// This comment used to claim "the shell does even when the `cua-driver` daemon
// does not", and two independent measurements falsified it. From an
// Elliot-spawned shell on 2026-08-07 it did not hold the grant, and the script
// reported nothing about it. From a `claude -p` run on 2026-08-08 (#132) the
// same, with receipts: `osascript` returns `-1719 not allowed assistive access`
// and `screencapture -x` returns `could not create image from display`.
//
// ⛔ Without the grant `CGEventPost` drops the events in silence and returns no
// receipt, so a click that never left and a click the app ignored would be
// indistinguishable from here. That is the same false negative one layer down —
// so this script **refuses by name** instead of exiting 0 on nothing, because a
// rule that lives only in a comment is a rule nobody re-runs. `AXIsProcessTrusted`
// answers instantly and never prompts. CLAUDE.md § *Watching the caret's anchors
// arrive* has the five probes and what still works without any grant.
import ApplicationServices
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: swift Scripts/realclick.swift <x> <y>\n".utf8))
    exit(64)
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(
        Data(
            """
            refusing to click: this process is not trusted for Accessibility, so the event would be \
            dropped in silence and this would exit 0 having done nothing.

            The grant belongs to the *responsible process* of this shell, which is not always the \
            terminal you typed in — an Elliot-spawned agent run is answerable for Elliot.app. Name \
            yours, then grant that app under System Settings > Privacy & Security > Accessibility:

              P=$PPID; while [ -n "$P" ] && [ "$P" -gt 1 ]; do ps -o pid=,comm= -p "$P" || break; \
            P=$(ps -o ppid= -p "$P" | tr -d ' '); done

            See CLAUDE.md, "Looking and touching are two different grants".

            """.utf8))
    exit(77)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)

// Move first. SwiftUI tracks hover, and a down/up pair at a point the pointer
// never travelled to can arrive at a view that never saw it enter.
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
