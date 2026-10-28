import AppKit
import SwiftUI

/// 设置 › 外观 里新加的几项（主题色、文件列表字号、边栏、缩略图、透视文件夹、应用图标）。
/// 一份 AppearanceSettings，改了马上存（UserDefaults「appearance.settings」）、马上生效。
@MainActor
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    @Published private(set) var settings: AppearanceSettings

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = AppearanceSettings.decode(defaults.data(forKey: AppearanceSettings.key))
    }

    func update(_ change: (inout AppearanceSettings) -> Void) {
        var copy = settings
        change(&copy)
        copy.listFontSize = ListFontSize.clamp(copy.listFontSize)
        guard copy != settings else { return }
        let old = settings
        settings = copy
        if let data = copy.encoded() { defaults.set(data, forKey: AppearanceSettings.key) }
        if old.appIcon != copy.appIcon { AltAppIcons.apply() }
        if old.peekFolders != copy.peekFolders || old.alwaysPreviewMedia != copy.alwaysPreviewMedia {
            PeekFolderCache.shared.settingsChanged()
        }
    }

    /// 设置页用的双向绑定。
    func binding<T>(_ keyPath: WritableKeyPath<AppearanceSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// 选了主题色时的颜色；默认（跟随系统）是 nil。
    var accentColor: Color? { settings.accent.color }
}

extension AccentChoice {
    var color: Color? {
        rgb.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1) }
    }

    /// 设置里圆点的颜色（默认那个画成系统强调色）。
    var swatch: Color { color ?? Color(nsColor: .controlAccentColor) }

    var title: String {
        switch self {
        case .system: return String(localized: "默认")
        case .blue: return String(localized: "蓝色")
        case .purple: return String(localized: "紫色")
        case .pink: return String(localized: "粉色")
        case .red: return String(localized: "红色")
        case .orange: return String(localized: "橙色")
        case .yellow: return String(localized: "黄色")
        case .green: return String(localized: "绿色")
        case .graphite: return String(localized: "石墨色")
        }
    }
}

/// 主题色：套在每个窗口的最外层。控件（开关、按钮、滑块、选中框）和用 Color.accentColor 画的地方都跟着变；
/// 选「默认」时什么都不加，和系统强调色一样。
struct AppAccentModifier: ViewModifier {
    @ObservedObject private var appearance = AppearanceStore.shared

    func body(content: Content) -> some View {
        if let color = appearance.accentColor {
            content
                .tint(color)
                .accentColor(color)
        } else {
            content
        }
    }
}

extension View {
    /// 跟着设置 › 外观 › 主题色。
    func appAccent() -> some View { modifier(AppAccentModifier()) }
}

// MARK: - 应用图标（Pro）

/// 备选 Dock 图标：只换运行时的程序坞图标（NSApplication.applicationIconImage），不改安装包里的文件，签名保持有效。
/// 图放在 App 里的 AltAppIcons 文件夹：<id>.png，正方形、建议 1024×1024（至少 512），四周留和系统图标一样的透明边。
/// 往 Resources/AltAppIcons 里放一张新的 PNG 就多一款，不用改代码（中文名在 title(for:) 里加一行）。
/// 现在 28 款（2026-10 设计师定稿）：小熊猫日常色、Pro 角标款、节日款、笑脸小电脑；渐变很重的几款是 640–768px 无损，其余 1024px。
/// 拾掇没在运行时，程序坞和访达里显示的仍是安装包自带的图标（系统限制）。
@MainActor
enum AltAppIcons {
    static let folderName = "AltAppIcons"

    private static var imageCache: [String: NSImage] = [:]

    /// App 里有哪几款（不含默认）。
    static var available: [String] {
        guard let folder = Bundle.main.url(forResource: folderName, withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return AltAppIconLogic.ids(fromFileNames: names)
    }

    static func url(for id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "png", subdirectory: folderName)
    }

    static func image(for id: String) -> NSImage? {
        if let hit = imageCache[id] { return hit }
        guard let url = url(for: id), let image = NSImage(contentsOf: url) else { return nil }
        imageCache[id] = image
        return image
    }

    /// 安装包自带的图标（设置里「默认」那一格）。
    static var defaultImage: NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    static func title(for id: String) -> String {
        switch id {
        case "panda-cream": return String(localized: "奶油白")
        case "panda-night": return String(localized: "夜色")
        case "panda-royal-pro": return String(localized: "宝蓝金")
        case "panda-gold-pro": return String(localized: "鎏金")
        case "panda-ruby-pro": return String(localized: "红宝石")
        case "panda-prism-pro": return String(localized: "棱镜")
        case "panda-blue-pro": return String(localized: "晴空蓝")
        case "panda-yellow-pro": return String(localized: "柠檬黄")
        case "panda-red-pro": return String(localized: "樱桃红")
        case "panda-purple-pro": return String(localized: "丁香紫")
        case "panda-rainbow-pro": return String(localized: "彩虹")
        case "panda-navy-pro": return String(localized: "藏青")
        case "panda-bronze-pro": return String(localized: "古铜")
        case "panda-wine-pro": return String(localized: "酒红")
        case "panda-grape-pro": return String(localized: "葡萄紫")
        case "panda-aurora-pro": return String(localized: "极光")
        case "panda-halloween": return String(localized: "小熊猫·万圣节")
        case "panda-christmas": return String(localized: "小熊猫·圣诞")
        case "mac-cream": return String(localized: "小电脑·奶白")
        case "mac-teal": return String(localized: "小电脑·青绿")
        case "mac-sky-pro": return String(localized: "小电脑·天蓝")
        case "mac-navy": return String(localized: "小电脑·深蓝")
        case "mac-red-pro": return String(localized: "小电脑·绯红")
        case "mac-rainbow-pro": return String(localized: "小电脑·彩虹")
        case "mac-leaf": return String(localized: "小电脑·青叶")
        case "mac-lavender": return String(localized: "小电脑·薰衣草")
        case "mac-halloween": return String(localized: "小电脑·万圣节")
        case "mac-christmas": return String(localized: "小电脑·圣诞")
        default: return id
        }
    }

    /// 现在真正用的那款（没解锁 Pro、文件不在了 → 默认）。
    static var effective: String? {
        AltAppIconLogic.resolve(AppearanceStore.shared.settings.appIcon, available: available, isPro: LicenseManager.shared.isPro)
    }

    /// 启动时、选了别的图标时、Pro 状态变了时调用。nil = 还原成安装包里的图标。
    static func apply() {
        guard !Demo.isOn else { return }
        if let id = effective, let image = image(for: id) {
            NSApplication.shared.applicationIconImage = image
        } else {
            NSApplication.shared.applicationIconImage = nil
        }
    }
}
