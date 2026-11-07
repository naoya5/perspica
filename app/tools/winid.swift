// Prints the window IDs of one process, so a screenshot can target a single
// window with `screencapture -l <id>`.
//
//   swift tools/winid.swift [process name]   # default: Yaku
import CoreGraphics
import Foundation

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Yaku"

guard let windows = CGWindowListCopyWindowInfo(
    [.optionAll, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not list windows\n".utf8))
    exit(1)
}

var found = false
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == name else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = bounds["X"] as? Double ?? 0
    let y = bounds["Y"] as? Double ?? 0
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
    let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("id=\(number) layer=\(layer) alpha=\(alpha) onscreen=\(onScreen) "
        + "x=\(Int(x)) y=\(Int(y)) w=\(Int(width)) h=\(Int(height))")
    found = true
}

if !found {
    FileHandle.standardError.write(Data("no windows for process \(name)\n".utf8))
    exit(1)
}
