import AppKit

/// 界面语言。默认跟随系统（系统是中文就用简体中文，其他语言都用英文）；
/// 也可以在设置里单独给拾掇指定语言，写入本应用的 AppleLanguages，重启后生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 选项名称：语言名用它自己的写法，方便看不懂当前界面语言的人也能找到。
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    private static let key = "AppleLanguages"

    /// 只看本应用自己存的设置，不看系统的全局语言列表。
    static var current: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?[key] as? [String])?.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// 启动时的设置，用来判断改动后是否需要重新打开。
    static let atLaunch = current

    /// 当前界面实际使用的语言。
    static var effective: AppLanguage {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: Self.key)
        default: UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
        UserDefaults.standard.synchronize()
    }

    /// 退出后重新打开拾掇。等当前进程完全退出再打开，避免两个实例抢同一个全局快捷键。
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try task.run()
        } catch {
            // 实在启动不了辅助进程，就用 NSWorkspace 直接再开一个实例。
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        }
        NSApp.terminate(nil)
    }
}
