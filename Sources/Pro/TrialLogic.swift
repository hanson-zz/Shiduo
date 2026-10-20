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
    /// 已激活的付费用户，但离线超过宽限期或系统时间不对：要联网校验（「立即校验」），不是试用结束，也不能开始试用。
    case needsCheck
    /// 激活过、现在这台 Mac 没有有效授权（解绑了，或者服务器判授权码不可用）：重新输入授权码 / 购买，不说「试用已结束」。
    case licenseInactive

    /// needsCheck：已激活且需要联网校验；everActivated：这台 Mac 激活过授权码。
    static func of(_ state: LicenseState, needsCheck: Bool = false, everActivated: Bool = false) -> ProAccess {
        switch state {
        case .pro, .trial: return .unlocked
        case .free, .expiredTrial:
            if needsCheck { return .needsCheck }
            if everActivated { return .licenseInactive }
            return state == .free ? .offerTrial : .trialEnded
        }
    }

    /// 菜单栏图标、刘海暂存架显示上锁卡片（不悄悄消失）的情况：用过 Pro、现在用不了。
    var isLockedOut: Bool {
        switch self {
        case .trialEnded, .needsCheck, .licenseInactive: return true
        case .unlocked, .offerTrial: return false
        }
    }
}

/// 什么时候可以开始试用：只有「免费版、从没开始过试用、也没激活过授权码」这一种情况。
/// 已激活但离线太久的付费用户（状态算出来是免费版）不能开始试用，不然会把试用白白用掉。
enum TrialStartRule {
    static func canStart(state: LicenseState, trialStart: Date?, activated: Bool = false, everActivated: Bool = false) -> Bool {
        state == .free && trialStart == nil && !activated && !everActivated
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

    /// 试用已结束、这次试用还没提醒过。
    /// - 已激活、激活过（解绑 / 授权码失效）的不提醒：原因不是试用结束。
    /// - 时钟被往回调（clockRolledBack）或试用其实还没到期（开始时间在「未来」）：不提醒，调用方也不写 marker，
    ///   时钟改回来以后到真正结束那天照常提醒。
    static func shouldAnnounce(state: LicenseState, activated: Bool, trialStart: Date?, announced: String?,
                               everActivated: Bool = false, clockRolledBack: Bool = false, now: Date = Date()) -> Bool {
        guard state == .expiredTrial, !activated, !everActivated, !clockRolledBack, let trialStart else { return false }
        let end = trialStart.addingTimeInterval(TimeInterval(LicenseConfig.trialDays) * 86_400)
        guard now >= end else { return false }
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
