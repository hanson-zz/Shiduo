import AppKit
import Combine
import Foundation
import UserNotifications

private let cleanupReminderID = "io.github.hanson-zz.shiduo.weeklyCleanup"

/// 每周一次的本地清理提醒（UserNotifications，不联网）。点通知打开清理页。
@MainActor
final class CleanupReminder: ObservableObject {
    static let shared = CleanupReminder()

    nonisolated static let enabledKey = "cleanupReminderEnabled"
    /// Calendar 的 weekday：1 = 周日 … 7 = 周六。
    nonisolated static let weekdayKey = "cleanupReminderWeekday"
    nonisolated static let hourKey = "cleanupReminderHour"

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    nonisolated static var weekday: Int {
        let value = UserDefaults.standard.integer(forKey: weekdayKey)
        return (1...7).contains(value) ? value : 7
    }
    nonisolated static var hour: Int {
        guard UserDefaults.standard.object(forKey: hourKey) != nil else { return 10 }
        return min(max(UserDefaults.standard.integer(forKey: hourKey), 0), 23)
    }

    /// 周几的中文名，下标是 Calendar 的 weekday。
    nonisolated static let weekdayNames: [Int: String] = [
        2: String(localized: "周一"), 3: String(localized: "周二"), 4: String(localized: "周三"), 5: String(localized: "周四"), 6: String(localized: "周五"), 7: String(localized: "周六"), 1: String(localized: "周日"),
    ]
    nonisolated static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    weak var store: LibraryStore?
    /// 通知中心的代理。AppDelegate 在 applicationDidFinishLaunching 里就设置好（见 installNotificationDelegate），
    /// 冷启动时点的通知按钮才不会丢。
    let delegate = CleanupReminderDelegate()
    /// 冷启动时点了「每周清理」通知、主窗口还没准备好：等 configure 时再打开清理页。
    private var pendingOpenCleanup = false
    @Published private(set) var denied = false

    private init() {}

    func configure(store: LibraryStore) {
        self.store = store
        installNotificationDelegate()
        if pendingOpenCleanup {
            pendingOpenCleanup = false
            openCleanup()
        }
    }

    /// 设置通知中心代理（重复调用没关系）。
    func installNotificationDelegate() {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== delegate { center.delegate = delegate }
    }

    /// 按当前设置重新安排通知；关掉或不是 Pro 时取消。
    /// 文字里的「本周可腾出 X GB」取安排时的清理扫描结果，所以清理扫描后会再调用一次。
    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [cleanupReminderID])
        guard Self.isEnabled, LicenseManager.shared.isPro else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        denied = !granted
        guard granted else { return }

        let bytes = store?.cleanup.totalBytes ?? 0
        let content = UNMutableNotificationContent()
        content.title = String(localized: "拾掇：该清理一下了")
        content.body = bytes > 0
            ? String(localized: "本周可腾出 \(bytes.byteText)，点这里打开清理。")
            : String(localized: "花一分钟看看有哪些可以清理的文件。")
        content.sound = .default

        var components = DateComponents()
        components.weekday = Self.weekday
        components.hour = Self.hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: cleanupReminderID, content: content, trigger: trigger)
        try? await center.add(request)
    }

    func openCleanup() {
        guard store != nil else {
            // 冷启动：主窗口还没配置好 store，等 configure 时再打开清理页。
            pendingOpenCleanup = true
            MainWindow.show()
            return
        }
        let store = self.store
        MainWindow.show { store?.openCleanup(nil) }
    }
}

/// 通知中心的代理：拾掇在前台时也显示横幅；点通知打开清理页。
final class CleanupReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        if id.hasPrefix(ReminderStore.idPrefix), let uuid = UUID(uuidString: String(id.dropFirst(ReminderStore.idPrefix.count))) {
            let action = response.actionIdentifier
            Task { @MainActor in
                ReminderStore.shared.handle(action: action, id: uuid)
            }
        } else if id == cleanupReminderID {
            Task { @MainActor in
                CleanupReminder.shared.openCleanup()
            }
        } else if id == trialReminderID {
            Task { @MainActor in
                TrialReminder.shared.enterLicense()
            }
        } else if id == trialEndedNotificationID {
            // 「试用已结束」通知：打开主窗口，弹出试用结束面板（可以购买或输入授权码）。
            Task { @MainActor in
                MainWindow.show { TrialExpiryNotice.shared.reopen() }
            }
        }
        completionHandler()
    }
}
