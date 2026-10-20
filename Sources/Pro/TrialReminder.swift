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
                Task { @MainActor in
                    await TrialReminder.shared.update()
                    await TrialExpiryNotice.shared.check()
                }
            }
    }

    /// 离试用结束不到一天的那段时间（和付费页的早鸟价同一个判断）。
    private func reminderDate(for end: Date) -> Date {
        ProPricing.reminderStart(for: end)
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
        content.body = String(localized: "早鸟价 \(ProPricing.earlyBirdPrice)（原价 \(ProPricing.price)），使用优惠码 \(ProPricing.earlyBirdCode)。点这里购买或输入授权码。")
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

    /// 打开 Pro 介绍页（那里可以输入授权码）。
    func enterLicense() {
        MainWindow.show { LicenseManager.shared.showPaywall = true }
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
                Text("拾掇 Pro 试用明天到期 · 早鸟价 \(ProPricing.earlyBirdPrice)（原价 \(ProPricing.price)），使用优惠码 \(ProPricing.earlyBirdCode)")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("购买") { reminder.buy() }
                    .buttonStyle(.borderedProminent)
                Button("输入授权码") { reminder.enterLicense() }
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

// MARK: - 试用结束

let trialEndedNotificationID = "io.github.hanson-zz.shiduo.trialEnded"

/// 试用结束时不悄悄停掉：发一条通知，主窗口弹一次面板，列出停下来的功能（菜单栏小助手、刘海暂存架、
/// 自动整理规则……），可以直接购买或输入授权码。同一次试用只提醒一次。
@MainActor
final class TrialExpiryNotice: ObservableObject {
    static let shared = TrialExpiryNotice()

    nonisolated static let announcedKey = "trialExpiryAnnouncedFor"

    @Published var showSheet = false
    @Published private(set) var stopped: [TrialExpiry.Stopped] = []

    private init() {}

    /// 授权状态变化时、启动时调用。
    func check() async {
        let license = LicenseManager.shared
        let start = LicenseKeychain.date(.trialStart)
        let announced = UserDefaults.standard.string(forKey: Self.announcedKey)
        guard TrialExpiry.shouldAnnounce(state: license.state, activated: license.isActivated,
                                         trialStart: start, announced: announced),
              let start else {
            if license.isPro { showSheet = false }
            return
        }
        UserDefaults.standard.set(TrialExpiry.marker(for: start), forKey: Self.announcedKey)
        stopped = TrialExpiry.stopped(Self.currentUsage())
        showSheet = true
        await notify()
    }

    /// 试用期间打开过的 Pro 功能（开关还开着、规则还在）。
    static func currentUsage() -> TrialExpiry.Usage {
        let defaults = UserDefaults.standard
        var usage = TrialExpiry.Usage()
        usage.menuBar = defaults.bool(forKey: "menuBarEnabled")
        usage.floatingShelf = defaults.bool(forKey: FloatingShelfController.enabledKey)
        usage.autoOrganizeRules = LibraryStore.shared?.organizer.rules.filter { $0.enabled && $0.isRunnable }.count ?? 0
        usage.cleanupReminder = CleanupReminder.isEnabled
        usage.quickPick = QuickPickController.isEnabled
        usage.fileReminders = ReminderStore.shared.count
        usage.savedSearches = SavedSearchStore.shared.searches.count
        return usage
    }

    private func notify() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [trialReminderID])
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "拾掇 Pro 试用已结束")
        let names = stopped.map(Self.title).joined(separator: String(localized: "、"))
        content.body = stopped.isEmpty
            ? String(localized: "免费功能照常可用。点这里购买 Pro 或输入授权码。")
            : String(localized: "已暂停：\(names)。点这里购买 Pro 或输入授权码。")
        content.sound = .default
        let request = UNNotificationRequest(identifier: trialEndedNotificationID, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        do {
            try await center.add(request)
        } catch {
            AppLog.license.error("Trial ended notice not scheduled: \(AppLog.describe(error), privacy: .public)")
        }
    }

    static func title(_ item: TrialExpiry.Stopped) -> String {
        switch item {
        case .menuBar: return String(localized: "菜单栏小助手")
        case .floatingShelf: return String(localized: "刘海 / 悬浮暂存架")
        case .autoOrganize(let rules): return String(localized: "\(rules) 条自动整理规则")
        case .cleanupReminder: return String(localized: "每周清理提醒")
        case .quickPick: return String(localized: "数字键直达")
        case .fileReminders(let count): return String(localized: "\(count) 个文件提醒")
        case .savedSearches(let count): return String(localized: "\(count) 个保存的搜索")
        }
    }

    static func symbol(_ item: TrialExpiry.Stopped) -> String {
        switch item {
        case .menuBar: return ProFeature.menuBar.symbol
        case .floatingShelf: return ProFeature.floatingShelf.symbol
        case .autoOrganize: return ProFeature.autoOrganize.symbol
        case .cleanupReminder: return ProFeature.cleanupReminder.symbol
        case .quickPick: return ProFeature.quickPick.symbol
        case .fileReminders: return ProFeature.fileReminder.symbol
        case .savedSearches: return ProFeature.savedSearch.symbol
        }
    }
}

/// 试用结束面板（主窗口里弹一次）：哪些功能停下了，购买 / 输入授权码。
struct TrialEndedSheet: View {
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var notice = TrialExpiryNotice.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("拾掇 Pro 试用已结束")
                    .font(.title2.weight(.bold))
            }
            if notice.stopped.isEmpty {
                Text("Pro 功能已经锁上，免费功能（浏览、搜索、清理、暂存架）照常可用。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("这些 Pro 功能已经暂停（设置都还在，升级后马上恢复）：")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notice.stopped, id: \.self) { item in
                        Label {
                            Text(TrialExpiryNotice.title(item))
                        } icon: {
                            Image(systemName: TrialExpiryNotice.symbol(item))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.08)))
                Text("免费功能（浏览、搜索、清理、暂存架）照常可用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProPriceLine()
            HStack {
                Button("以后再说") { notice.showSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("输入授权码…") {
                    notice.showSheet = false
                    license.showPaywall = true
                }
                Button {
                    NSWorkspace.shared.open(LicenseConfig.buyURL)
                } label: {
                    Text("购买 Pro · \(ProPricing.price)")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
