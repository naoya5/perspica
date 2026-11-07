import Foundation
import ServiceManagement

/// 「ログイン時に起動」 through `SMAppService.mainApp` (SPEC 4.4, 10).
///
/// The app has to live in `~/Applications` for this to work, which is where
/// `make-app.sh install` puts it.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "オン"
        case .notRegistered: "オフ"
        case .requiresApproval: "システム設定での承認が必要"
        case .notFound: "アプリが見つかりません"
        @unknown default: "不明"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppLog.write("login item: enabled=\(enabled) status=\(SMAppService.mainApp.status.rawValue)")
            return true
        } catch {
            AppLog.write("login item: failed enabled=\(enabled) \(error)")
            return false
        }
    }
}
