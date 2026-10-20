import Foundation

// MARK: - 碰到 Pro 功能时显示什么（纯逻辑，单元测试覆盖）

/// 试用从不自动开始：打开 Pro 页面、右键点 Pro 项、打开图片工具，都只显示介绍和「开始 7 天免费试用」按钮，
/// 用户点了那个按钮才开始计时。
enum ProAccess: Equatable {
    /// Pro 已激活或试用中：直接用。
    case unlocked
    /// 还没试用过：主按钮是「开始 7 天免费试用」（不用注册）。
    case offerTrial
    /// 试用已经结束：购买 / 输入授权码。
    case trialEnded

    static func of(_ state: LicenseState) -> ProAccess {
        switch state {
        case .pro, .trial: return .unlocked
        case .free: return .offerTrial
        case .expiredTrial: return .trialEnded
        }
    }
}

/// 什么时候可以开始试用：只有「免费版、从没开始过试用」这一种情况。
enum TrialStartRule {
    static func canStart(state: LicenseState, trialStart: Date?) -> Bool {
        state == .free && trialStart == nil
    }
}

// MARK: - 价格

/// 付费页、到期提醒、试用结束面板共用的价格和条款（只在这里写一次）。
enum ProPricing {
    static let price = "$9.90"
    static let earlyBirdPrice = "$6.90"
    static let earlyBirdCode = "EARLYBIRD"
    static let refundDays = 14

    /// 早鸟价在什么时候有效：和 TrialReminder 一样，只在试用的最后一天（到期前 24 小时内）。
    static func earlyBirdActive(state: LicenseState, trialEnd: Date?, now: Date) -> Bool {
        guard case .trial = state, let end = trialEnd else { return false }
        return now >= reminderStart(for: end) && now < end
    }

    /// 到期提醒（通知和首页横幅）开始的时间：到期前一天。
    static func reminderStart(for end: Date) -> Date {
        end.addingTimeInterval(-86_400)
    }
}

// MARK: - 试用结束

/// 试用结束时提醒一次，列出停下来的 Pro 功能（纯逻辑）。
enum TrialExpiry {
    /// 这次试用结束后有没有提醒过：存的是那次试用开始的时间。
    static func marker(for trialStart: Date) -> String {
        String(Int(trialStart.timeIntervalSince1970))
    }

    /// 试用已结束、这次试用还没提醒过（已激活的不提醒）。
    static func shouldAnnounce(state: LicenseState, activated: Bool, trialStart: Date?, announced: String?) -> Bool {
        guard state == .expiredTrial, !activated, let trialStart else { return false }
        return announced != marker(for: trialStart)
    }

    /// 试用期间用户打开过的 Pro 功能。
    struct Usage: Equatable {
        var menuBar = false
        var floatingShelf = false
        var autoOrganizeRules = 0
        var cleanupReminder = false
        var quickPick = false
        var fileReminders = 0
        var savedSearches = 0
    }

    enum Stopped: Equatable, Hashable {
        case menuBar
        case floatingShelf
        case autoOrganize(rules: Int)
        case cleanupReminder
        case quickPick
        case fileReminders(count: Int)
        case savedSearches(count: Int)
    }

    /// 停下来的功能，按用户最容易注意到的顺序。
    static func stopped(_ usage: Usage) -> [Stopped] {
        var list: [Stopped] = []
        if usage.menuBar { list.append(.menuBar) }
        if usage.floatingShelf { list.append(.floatingShelf) }
        if usage.autoOrganizeRules > 0 { list.append(.autoOrganize(rules: usage.autoOrganizeRules)) }
        if usage.cleanupReminder { list.append(.cleanupReminder) }
        if usage.quickPick { list.append(.quickPick) }
        if usage.fileReminders > 0 { list.append(.fileReminders(count: usage.fileReminders)) }
        if usage.savedSearches > 0 { list.append(.savedSearches(count: usage.savedSearches)) }
        return list
    }
}
