import AppKit

/// 外观：跟随系统（默认）/ 浅色 / 深色。设置 › 外观 里切换，存在 UserDefaults「appearanceMode」。
/// 直接改 NSApp.appearance，所有窗口（主窗口、设置、付费页、图片工作室、暂存架、菜单栏浮窗、各种面板）都跟着变；
/// 自己强制深色的部分（刘海暂存架）不受影响。演示模式用 --dark 时以演示为准，这里不改。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "appearanceMode"
    var id: Self { self }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// 启动时（窗口出现前）和设置改动时调用。
    @MainActor
    func apply() {
        guard !Demo.isOn else { return }
        NSApplication.shared.appearance = nsAppearance
    }
}
