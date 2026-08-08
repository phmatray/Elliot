// Lists a process's windows — id, on-screen flag, size and position.
//
//     swift Scripts/list-windows.swift [<pid>]
//
// With no pid it lists every application's windows. Find Elliot's pid with:
//
//     ps -eo pid,command | grep 'MacOS/Elliot$' | grep -v grep
//
// ⛔ **Do not use `pgrep -f` to find it from an Elliot-spawned agent shell.**
// `pgrep` excludes *its own ancestors* by default (`man pgrep`: `-a` "Include
// process ancestors in the match list"), and an agent run's ancestor chain is
// `zsh ← claude ← Elliot`. So `pgrep -f 'Elliot.app/Contents/MacOS/Elliot'`
// returns **nothing** while `pgrep -a -f …` returns 45434 — measured
// 2026-08-07. It is not that GUI apps are invisible: `pgrep -f
// 'Arc.app/Contents/MacOS/Arc'` finds Arc from the same shell. It is that the
// app you are debugging is the app that started you.
//
// ⛔ **Never filter on `isOnScreen`.** A window that is not frontmost reports
// false and is still open at its full designed size; filtering on it is how
// "the secondary window didn't open" got written down nine times. See CLAUDE.md
// § "A secondary window is verifiable too".
//
// ⚠️ **Without Screen Recording every `title` is empty** while the geometry is
// perfect — a list that looks complete and is wrong in one column. This script
// says so rather than letting you read it as "the windows are unnamed".
// Disambiguate by *size* instead: the board is ~1510×925, Preflight 820×720,
// Repositories 900×700, and a 1728×33 entry is a titlebar shim, not a window.
//
// `CGWindowListCopyWindowInfo` is NOT the obsoleted `CGWindowListCreateImage`;
// it still compiles on our declared floor and needs no grant for geometry.
import CoreGraphics
import Foundation

let pid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil

guard
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("CGWindowListCopyWindowInfo returned nil\n".utf8))
    exit(1)
}

var matched = 0
var named = 0

for window in windows {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int else { continue }
    if let pid, owner != pid { continue }
    matched += 1

    let id = window[kCGWindowNumber as String] as? Int ?? -1
    let title = window[kCGWindowName as String] as? String ?? ""
    if !title.isEmpty { named += 1 }
    let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
    let app = window[kCGWindowOwnerName as String] as? String ?? "?"
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let w = bounds["Width"] as? Double ?? 0
    let h = bounds["Height"] as? Double ?? 0
    let x = bounds["X"] as? Double ?? 0
    let y = bounds["Y"] as? Double ?? 0

    let size = String(format: "%.0fx%.0f @ (%.0f,%.0f)", w, h, x, y)
    print("pid=\(owner) id=\(id) on_screen=\(onScreen) \(size) app='\(app)' title='\(title)'")
}

if matched == 0 {
    FileHandle.standardError.write(
        Data("no windows matched\(pid.map { " pid \($0)" } ?? "")\n".utf8))
}

// Name the false negative rather than leaving it to be misread.
if matched > 0, named == 0, !CGPreflightScreenCaptureAccess() {
    FileHandle.standardError.write(
        Data(
            """

            note: every title above is empty because this process's responsible app does not hold \
            Screen Recording (CGPreflightScreenCaptureAccess() == false). The geometry is real; the \
            names are withheld. Disambiguate by size, not by name.

            """.utf8))
}
