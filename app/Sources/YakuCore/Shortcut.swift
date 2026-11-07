import Foundation

/// The modifier keys of a global shortcut, in a form that does not depend on
/// AppKit so it can be tested in `YakuCore` (SPEC 12).
public struct ShortcutModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)

    /// Apple's display order: ⌃⌥⇧⌘.
    public var display: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// One global shortcut: a virtual key code plus its modifiers.
public struct Shortcut: Sendable, Hashable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A shortcut only counts when it has at least one modifier; otherwise it
    /// would swallow ordinary typing everywhere.
    public var isUsable: Bool { !modifiers.isEmpty }

    public var display: String { modifiers.display + Shortcut.keyName(for: keyCode) }

    /// Names for the virtual key codes the recorder can produce. Anything not
    /// listed falls back to `Key<code>`, which is still unambiguous.
    public static func keyName(for keyCode: UInt16) -> String {
        if let name = names[keyCode] { return name }
        return "Key\(keyCode)"
    }

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘",
        120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// A named shortcut in the settings window (SPEC 4.4: 選択文を訳す / パネル /
/// 画面を翻訳). `shortcut == nil` means the user cleared it.
public struct ShortcutBinding: Sendable, Equatable {
    public let id: String
    public var shortcut: Shortcut?

    public init(id: String, shortcut: Shortcut?) {
        self.id = id
        self.shortcut = shortcut
    }
}

/// Stores a `Shortcut` in defaults as `keyCode:modifiers`.
public enum ShortcutCodec {
    public static func encode(_ shortcut: Shortcut) -> String {
        "\(shortcut.keyCode):\(shortcut.modifiers.rawValue)"
    }

    public static func decode(_ text: String) -> Shortcut? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt16(parts[0]),
              let modifiers = UInt32(parts[1])
        else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: ShortcutModifiers(rawValue: modifiers))
    }
}

/// Overlap detection for the shortcut recorder (SPEC 4.4: 重なったら警告).
public enum ShortcutConflict {
    /// Every pair of bindings that use the same key and modifiers. A cleared
    /// binding never conflicts.
    public static func pairs(_ bindings: [ShortcutBinding]) -> [(String, String)] {
        var result: [(String, String)] = []
        let usable = bindings.compactMap { binding -> (String, Shortcut)? in
            guard let shortcut = binding.shortcut, shortcut.isUsable else { return nil }
            return (binding.id, shortcut)
        }
        for outer in usable.indices {
            for inner in usable.index(after: outer)..<usable.endIndex {
                if usable[outer].1 == usable[inner].1 {
                    result.append((usable[outer].0, usable[inner].0))
                }
            }
        }
        return result
    }

    /// The ids involved in any overlap, for marking the fields.
    public static func conflictingIDs(_ bindings: [ShortcutBinding]) -> Set<String> {
        var ids = Set<String>()
        for (first, second) in pairs(bindings) {
            ids.insert(first)
            ids.insert(second)
        }
        return ids
    }
}
