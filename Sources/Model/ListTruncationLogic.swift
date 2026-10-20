import Foundation

/// 列表到了上限（3000 / 2000 / 5000 个）被截断时怎么提示（纯逻辑，单元测试覆盖）。
/// 侧边栏角标是全量计数，列表只取前 N 个：不说清楚，用户会以为漏扫了。
enum ListTruncation {
    /// 取前 N 个时按的顺序。
    enum Order: Equatable {
        case recent
        case largest
        case name
    }

    /// 截断了就返回一共有多少个；没截断（或不知道总数）返回 nil。
    static func hiddenTotal(shown: Int, total: Int?, cap: Int?) -> Int? {
        guard let total, let cap, cap > 0, shown >= cap, total > shown else { return nil }
        return total
    }

    /// 侧边栏 / 副标题里的数字：超过上限时写「3000+」，没上限照常写数字。
    static func countLabel(_ count: Int, cap: Int?) -> String {
        guard let cap, count > cap else { return "\(count)" }
        return "\(cap)+"
    }

    /// 列表顶部那一条：「只显示最近 3000 项，共 12480 项 · 用搜索缩小范围」。
    static func bannerText(cap: Int, total: Int, order: Order) -> String {
        switch order {
        case .recent: return String(localized: "只显示最近 \(cap) 项，共 \(total) 项 · 用搜索缩小范围")
        case .largest: return String(localized: "只显示最大的 \(cap) 项，共 \(total) 项 · 用搜索缩小范围")
        case .name: return String(localized: "只显示前 \(cap) 项，共 \(total) 项 · 用搜索缩小范围")
        }
    }
}
