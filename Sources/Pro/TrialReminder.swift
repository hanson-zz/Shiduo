import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

let trialReminderID = "io.github.hanson-zz.shiduo.trialEnding"

/// 试用到期前一天提醒一次：一条本地通知（只发一次）+ 首页横幅（关掉后不再出现）。已激活 Pro 的用户不提醒。
@MainActor
final class TrialReminder: ObservableObject {
    static let shared = TrialReminder()

    /// 存的是已经安排过提醒的那次试用的开始时间，保证同一次试用只提醒一次。
    nonisolated static let notifiedKey = "trialReminderNotifiedFor"
    nonisolated static let bannerDismissedKey = "trialReminderBannerDismissed"

    /// 首页是否显示「试用明天到期」横幅。
    @Published private(set) var showBanner = false

    private var cancellable: AnyCancellable?

    private init() {}

    /// 启动时调用一次；之后授权状态变化（开始试用、激活）时自动更新。
    func start() {
        guard cancellable == nil else { return }
        cancellable = LicenseManager.shared.$state
            .removeDuplicates()
            .sink { _ in
                Task { @MainActor in await TrialReminder.shared.update() }
            }
    }

    /// 离试用结束不到一天的那段时间。
    private func reminderDate(for end: Date) -> Date {
        end.addingTimeInterval(-86_400)
    }

    func update() async {
        let license = LicenseManager.shared
        let center = UNUserNotificationCenter.current()
        guard case .trial = license.state, let end = license.trialEndDate else {
            // 已激活、试用结束或没开始：不提醒，撤掉还没发出的通知。
            showBanner = false
            if license.state == .pro { center.removePendingNotificationRequests(withIdentifiers: [trialReminderID]) }
            return
        }
        let now = Date()
        let remindAt = reminderDate(for: end)
        let dismissed = UserDefaults.standard.bool(forKey: Self.bannerDismissedKey)
        showBanner = now >= remindAt && now < end && !dismissed

        let marker = String(Int(end.timeIntervalSince1970))
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != marker, now < end else { return }
        // 第一次需要时才请求通知权限。
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "拾掇 Pro 试用明天到期")
        content.body = String(localized: "早鸟价 $6.90（原价 $9.90），使用优惠码 EARLYBIRD。点这里购买或输入许可证。")
        content.sound = .default
        let trigger: UNNotificationTrigger
        if now < remindAt {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: remindAt.timeIntervalSince(now), repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        }
        let request = UNNotificationRequest(identifier: trialReminderID, content: content, trigger: trigger)
        do {
            try await center.add(request)
            UserDefaults.standard.set(marker, forKey: Self.notifiedKey)
        } catch {
            AppLog.license.error("Trial reminder not scheduled: \(AppLog.describe(error), privacy: .public)")
        }
    }

    func dismissBanner() {
        UserDefaults.standard.set(true, forKey: Self.bannerDismissedKey)
        showBanner = false
    }

    func buy() {
        NSWorkspace.shared.open(LicenseConfig.buyURL)
    }

    /// 打开主窗口里的 Pro 介绍页（那里可以输入许可证）。
    func enterLicense() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        LicenseManager.shared.showPaywall = true
    }
}

/// 首页顶部的试用到期横幅。
struct TrialEndingBanner: View {
    @ObservedObject private var reminder = TrialReminder.shared

    var body: some View {
        if reminder.showBanner {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("拾掇 Pro 试用明天到期 · 早鸟价 $6.90（原价 $9.90），使用优惠码 EARLYBIRD")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("购买") { reminder.buy() }
                    .buttonStyle(.borderedProminent)
                Button("输入许可证") { reminder.enterLicense() }
                Button {
                    reminder.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("不再显示")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        }
    }
}
