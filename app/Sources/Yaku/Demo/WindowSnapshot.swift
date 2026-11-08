import AppKit

/// `--demo-snapshot-at`: draws every visible Yaku window into a PNG from inside
/// the app, under `<data dir>/snapshots/`.
///
/// It needs no screen recording permission, which `screencapture` does, so a
/// terminal without that permission can still check what a control shows.
/// Materials and Liquid Glass are drawn by the window server, not by the view,
/// so they come out clear: use `screencapture` for how the glass looks.
@MainActor
enum WindowSnapshot {
    static func writeAll(label: String) {
        let directory = AppPaths.supportDirectory.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView,
                  view.bounds.width >= 120, view.bounds.height >= 24,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("\(label)-w\(window.windowNumber).png")
            do {
                try png.write(to: url)
                AppLog.write("demo: snapshot \(url.lastPathComponent) "
                    + "\(Int(view.bounds.width))x\(Int(view.bounds.height))")
            } catch {
                AppLog.write("demo: snapshot failed \(url.lastPathComponent): \(error)")
            }
        }
    }
}
