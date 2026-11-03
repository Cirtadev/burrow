import AppKit
import UserNotifications

/// Banners for things that happen while the user isn't looking: a reconnect, or a code needed to reconnect.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let profileKey = "profileID"
    nonisolated static let approvalKey = "opensApprovalSettings"
    private let center = UNUserNotificationCenter.current()
    var isEnabled: () -> Bool = { true }
    /// Called when the user clicks a "code needed" banner.
    var onOpenSignIn: ((UUID) -> Void)?
    /// Called when the user clicks the "allow Burrow's VPN" banner.
    var onOpenApprovalSettings: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ title: String, _ body: String, signInProfile: UUID? = nil, opensApprovalSettings: Bool = false) {
        guard isEnabled() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if opensApprovalSettings {
            content.userInfo = [Self.approvalKey: true]
        }
        if let signInProfile {
            content.userInfo = [Self.profileKey: signInProfile.uuidString]
            content.sound = .default
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info[Self.profileKey] as? String).flatMap(UUID.init(uuidString:))
        let approval = info[Self.approvalKey] as? Bool ?? false
        completionHandler()
        Task { @MainActor in
            if approval { self.onOpenApprovalSettings?() }
            if let id { self.onOpenSignIn?(id) }
        }
    }
}
