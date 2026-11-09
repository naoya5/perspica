import Foundation

/// Launch options (SPEC 15). M2 adds the manager, settings and onboarding
/// surfaces, the page inside them, and `--data-dir`.
struct DemoOptions {
    /// `--demo-surface panel|hud|manager|settings|onboarding|notch|overlay`
    var surface: String?
    /// `--demo-state empty|translating|done|error|no-permission`
    var state: String?
    /// `--demo-text "<文>"`
    var text: String?
    /// `--demo-anchor <x>,<y>`: where the HUD points, in the same coordinate
    /// space as accessibility bounds (origin at the top left of the main
    /// display, y growing downward).
    var anchor: CGPoint?
    /// `--demo-glow <秒>`: hold the processing light on without translating.
    var glowSeconds: Double?
    /// `--demo-pin`: pin the panel and the HUD, so a stray click during a
    /// screenshot does not close them.
    var pin = false
    /// `--demo-translate "<英文>"`: translate headlessly and exit.
    var translate: String?
    /// `--demo-quit-after <秒>`
    var quitAfter: Double?
    /// `--appearance light|dark`
    var appearance: String?
    /// `--engine-idle-seconds <秒>`
    var engineIdleSeconds: Double?
    /// `--demo-page translate|pdf|history|glossary|models` for the manager, or
    /// `1`〜`4` for the onboarding.
    var page: String?
    /// `--demo-search "<語>"`: type this into the history page's search field.
    var search: String?
    /// `--demo-tab 一般|ショートカット|エンジン|PDF|画面翻訳|プライバシー`
    var tab: String?
    /// `--data-dir <フォルダ>`: use this folder instead of Application Support.
    var dataDir: String?
    /// `--demo-glossary off`: ignore the glossary, for the before/after check.
    var glossaryEnabled = true
    /// `--demo-first-run`: show the onboarding even if it has been seen.
    var forceOnboarding = false
    /// `--demo-download <0.8b|2b|8b>`: fetch that model on launch, so the
    /// download path can be checked without clicking. The licence is accepted
    /// as part of the option (the sheet itself still needs a hand).
    var downloadModelID: String?
    /// `--demo-download-cancel <秒>`: stop the transfer after this many
    /// seconds, keeping the partial file so the next run resumes it.
    var downloadCancelAfter: Double?
    /// `--demo-download-gate`: ask for the licence instead of starting, so the
    /// sheet can be photographed.
    var downloadGate = false
    /// `--demo-close-after <秒>`: close the hand-opened windows again, so the
    /// memory after closing can be measured.
    var closeWindowsAfter: Double?
    /// `--demo-pdf <path>`: translate that PDF through the same path a drop
    /// takes (SPEC 15).
    var pdf: String?
    /// `--pdf-pages <範囲>`: pages to translate, e.g. `1-3`.
    var pdfPages: String?
    /// `--pdf-python <path>`: use this interpreter for the PDF worker instead
    /// of the installed environment (SPEC 8.2, development).
    var pdfPython: String?
    /// `--demo-translate-after <秒>`: start a panel translation this long after
    /// launch, so a PDF job and a panel translation really overlap (SPEC 7.3).
    var translateAfter: Double?
    /// `--demo-cancel-after <秒>`: cancel the running PDF job this long after
    /// launch, so the cancel path can be checked without clicking (SPEC 8.2).
    var cancelAfter: Double?
    /// `--demo-copy-at <秒>[,<秒>…]`: press ⌘⇧C in the panel (⌘C in the HUD)
    /// at these times after launch. The key goes into the app's own event
    /// queue, so it takes the same key monitor a real press does.
    var copyAt: [Double] = []
    /// `--demo-reject-at <秒>[,<秒>…]`: drop a file that is not a PDF on the
    /// island at these times after launch, through the same refusal a real drop
    /// gets (SPEC 4.5).
    var rejectAt: [Double] = []
    /// `--demo-snapshot-at <秒>[,<秒>…]`: draw the visible windows into PNGs
    /// at these times after launch (`WindowSnapshot`), for a terminal that has
    /// no screen recording permission.
    var snapshotAt: [Double] = []
    /// `--demo-click <x>,<y>` with `--demo-click-at <秒>[,<秒>…]`: click that
    /// point of the frontmost normal window (points from its top left, as in a
    /// window capture) at these times. The click goes into the app's own event
    /// queue, so the control under it handles it like a real click.
    var clickPoint: CGPoint?
    var clickAt: [Double] = []
    /// `--demo-image <png>`: read that image instead of the screen and lay the
    /// translation over it, placed from the screen's top left (SPEC 15, M4).
    var demoImage: String?
    /// `--demo-scale <倍率>`: the scale the demo image was captured at, so its
    /// pixels map onto points (SPEC 15, M4).
    var demoScale: Double?
    /// `--demo-dump-blocks`: print the blocks read from `--demo-image` as JSON
    /// and exit, so the reading can be checked without a screen (M4).
    var dumpBlocks = false
    /// `--demo-pdf-worker installed`: report the PDF worker as installed, so the
    /// settings tab's 導入済み state can be photographed without the download
    /// (SPEC 15, M5).
    var pdfWorkerDemoInstalled = false
    /// `--demo-reduce-motion` / `--demo-reduce-transparency` /
    /// `--demo-increase-contrast`: draw the accessibility appearance without
    /// changing the system's own settings (SPEC 15, M5).
    var reduceMotionDemo = false
    var reduceTransparencyDemo = false
    var increaseContrastDemo = false
    /// `--demo-backdrop light|dark`: put a full-screen picture-like backdrop
    /// behind the glass, so the panel, HUD, island and overlay can be captured
    /// over a bright or a dark background without changing the wallpaper
    /// (SPEC 15, M5).
    var backdrop: String?

    static let current = DemoOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch arguments[index] {
            case "--demo-surface": surface = next()
            case "--demo-state": state = next()
            case "--demo-text": text = next()
            case "--demo-anchor": anchor = next().flatMap(Self.parseAnchor)
            case "--demo-glow": glowSeconds = next().flatMap(Double.init)
            case "--demo-pin": pin = true
            case "--demo-translate": translate = next()
            case "--demo-quit-after": quitAfter = next().flatMap(Double.init)
            case "--appearance": appearance = next()
            case "--engine-idle-seconds": engineIdleSeconds = next().flatMap(Double.init)
            case "--demo-page": page = next()
            case "--demo-tab": tab = next()
            case "--demo-search": search = next()
            case "--data-dir": dataDir = next()
            case "--demo-glossary":
                let value = next()
                glossaryEnabled = value != "off"
            case "--demo-first-run": forceOnboarding = true
            case "--demo-download": downloadModelID = next()
            case "--demo-download-cancel": downloadCancelAfter = next().flatMap(Double.init)
            case "--demo-download-gate": downloadGate = true
            case "--demo-close-after": closeWindowsAfter = next().flatMap(Double.init)
            case "--demo-pdf": pdf = next()
            case "--pdf-pages": pdfPages = next()
            case "--pdf-python": pdfPython = next()
            case "--demo-translate-after": translateAfter = next().flatMap(Double.init)
            case "--demo-cancel-after": cancelAfter = next().flatMap(Double.init)
            case "--demo-copy-at": copyAt = Self.parseTimes(next())
            case "--demo-reject-at": rejectAt = Self.parseTimes(next())
            case "--demo-snapshot-at": snapshotAt = Self.parseTimes(next())
            case "--demo-click": clickPoint = next().flatMap(Self.parseAnchor)
            case "--demo-click-at": clickAt = Self.parseTimes(next())
            case "--demo-image": demoImage = next()
            case "--demo-scale": demoScale = next().flatMap(Double.init)
            case "--demo-dump-blocks": dumpBlocks = true
            case "--demo-pdf-worker":
                pdfWorkerDemoInstalled = next() == "installed"
            case "--demo-reduce-motion": reduceMotionDemo = true
            case "--demo-reduce-transparency": reduceTransparencyDemo = true
            case "--demo-increase-contrast": increaseContrastDemo = true
            case "--demo-backdrop": backdrop = next()
            default: break
            }
            index += 1
        }
    }

    static func parseAnchor(_ value: String) -> CGPoint? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// `"20,20.8"` → `[20, 20.8]`; a part that is not a number is skipped.
    static func parseTimes(_ value: String?) -> [Double] {
        (value ?? "").split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
    }
}
