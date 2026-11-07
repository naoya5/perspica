// Prints the accessibility tree of one process, so the VoiceOver names and
// roles can be checked without turning VoiceOver on.
//
//   swiftc -O tools/axdump.swift -o /tmp/axdump
//   /tmp/axdump Yaku
//
// Needs the calling process to hold the Accessibility permission; without it
// every AX call returns kAXErrorAPIDisabled (-25211).
import ApplicationServices
import AppKit
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Yaku"

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == target }) else {
    FileHandle.standardError.write(Data("no running application named \(target)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

var visited = 0
func walk(_ element: AXUIElement, depth: Int) {
    guard visited < 400, depth < 14 else { return }
    visited += 1
    let role = string(element, kAXRoleAttribute) ?? "?"
    let title = string(element, kAXTitleAttribute) ?? ""
    let description = string(element, kAXDescriptionAttribute) ?? ""
    let value = string(element, kAXValueAttribute) ?? ""
    var line = String(repeating: "  ", count: depth) + role
    if !title.isEmpty { line += " title=\"\(title)\"" }
    if !description.isEmpty { line += " desc=\"\(description)\"" }
    if !value.isEmpty {
        let short = value.count > 60 ? String(value.prefix(60)) + "…" : value
        line += " value=\"\(short)\""
    }
    print(line)

    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children { walk(child, depth: depth + 1) }
    }
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
var windowsValue: CFTypeRef?
let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
guard result == .success, let windows = windowsValue as? [AXUIElement] else {
    FileHandle.standardError.write(Data("could not read windows (AXError \(result.rawValue)); accessibility permission is needed\n".utf8))
    exit(2)
}

for window in windows {
    print("=== window ===")
    walk(window, depth: 0)
}
