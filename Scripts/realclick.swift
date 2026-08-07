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
// ⚠️ Posting events needs the caller to hold Accessibility, and **whether your
// shell holds it depends on which shell you are.** This comment used to say the
// shell does even when the `cua-driver` daemon does not; measured from a
// `claude -p` run on 2026-08-08 (#132) that is false — `osascript` returns
// `-1719 not allowed assistive access` and `screencapture -x` returns
// `could not create image from display`. An interactive Terminal someone ticked
// the box for is a different TCC identity from a spawned agent. Without the
// grant the events are dropped in silence — the same false negative one layer
// down, so if every click appears to do nothing, check the grant before
// believing the app. CLAUDE.md § *Watching the caret's anchors arrive* has the
// five probes and what still works without any grant.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: swift Scripts/realclick.swift <x> <y>\n".utf8))
    exit(64)
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
