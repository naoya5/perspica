import Foundation
@preconcurrency import UserNotifications

/// The completion notification (SPEC 8.3): shown when a PDF finishes and the
/// panel is closed, with an 「開く」 action.
///
/// Permission is asked for the first time a notification is actually needed,
/// never at launch, and nothing in the system settings is changed.
@MainActor
final class PDFNotifications: NSObject {
    static let shared = PDFNotifications()

    nonisolated static let categoryID = "YAKU_PDF_DONE"
    nonisolated static let openActionID = "YAKU_PDF_OPEN"
    nonisolated static let pathKey = "path"

    private var configured = false

    /// Opens the file the notification's action points at.
    var onOpen: ((String) -> Void)?

    /// `UNUserNotificationCenter.current()` needs a bundle identifier, which is
    /// absent when the executable is run outside the bundle.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func configure() {
        guard isAvailable, !configured else { return }
        configured = true
        let center = UNUserNotificationCenter.current()
        let open = UNNotificationAction(
            identifier: Self.openActionID,
            title: "開く",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.delegate = self
    }

    /// Posts the notification for a finished job, asking for permission the
    /// first time (SPEC 10: 権限は使う直前に聞く).
    func notifyFinished(fileName: String, path: String) {
        guard isAvailable, !path.isEmpty else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                AppLog.write("notify: permission not granted")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "PDF を訳しました"
            content.body = fileName
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.pathKey: path]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    AppLog.write("notify: add failed \(error)")
                } else {
                    AppLog.write("notify: posted for \(fileName)")
                }
            }
        }
    }
}

extension PDFNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.openActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else { return }
        await MainActor.run {
            AppLog.write("notify: opening \(path)")
            onOpen?(path)
        }
    }

    /// Shown even while Yaku is frontmost, because the notification is about a
    /// file the user asked for.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
