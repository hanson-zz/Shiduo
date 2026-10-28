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

/// 备选应用图标（Pro）：两处一起换——
/// 1. 运行时的程序坞图标（NSApplication.applicationIconImage），马上生效；
/// 2. 安装包本身的自定义图标（NSWorkspace.setIcon 写到 拾掇.app 根目录的「Icon\r」+ FinderInfo 标记），
///    这样「应用程序」文件夹（访达）里、以及退出后的程序坞里也是这款。还原成默认（选了默认 / Pro 到期 / 文件不在了）
///    时用 setIcon(nil) 去掉自定义图标。写进安装包的是哪款记在 UserDefaults「appliedBundleIconID」，启动时不重复写；
///    App 被更新 / 替换后 Icon\r 没了，启动时自动补上（判断都在 BundleIconLogic）。
///    没有写入权限（比如别的管理员装在 /Applications）时只换程序坞，设置里那行小字会说明。
///
/// 代价：往包根目录加 Icon\r 会让代码签名的「封印」对不上（codesign --verify 报 unsealed contents），
/// 访达「显示简介」手动换图标也是一样的效果，App 照常能打开。拾掇运行时不校验自己的签名
/// （授权文件的 HMAC 用的是本机硬件 UUID，自动更新只比 bundle id），所以不受影响。
/// 但「完全磁盘访问权限」这类隐私授权按代码签名认 App，第一次写图标后个别系统版本可能要在
/// 系统设置 › 隐私与安全性 里把拾掇关掉再打开（重新授权）一次。
///
/// 图放在 App 里的 AltAppIcons 文件夹：<id>.png，正方形、建议 1024×1024（至少 512），四周留和系统图标一样的透明边。
/// 往 Resources/AltAppIcons 里放一张新的 PNG 就多一款，不用改代码（中文名在 title(for:) 里加一行）。
/// 现在 28 款（2026-10 设计师定稿）：小熊猫日常色、Pro 角标款、节日款、笑脸小电脑；渐变很重的几款是 640–768px 无损，其余 1024px。
/// 演示模式不碰（DemoExtras 自己给示例 App 设图标）。
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

    /// 安装包自带的图标（设置里「默认」那一格）。直接读包里的 AppIcon.icns：
    /// 写过自定义图标后 NSWorkspace.icon(forFile:) 拿到的是换过的那款，不能用来当「默认」。
    static var defaultImage: NSImage {
        if let cached = defaultImageCache { return cached }
        let image = Bundle.main.image(forResource: NSImage.Name("AppIcon"))
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        defaultImageCache = image
        return image
    }

    private static var defaultImageCache: NSImage?

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
        var bundleID: String?
        if let id = effective, let image = image(for: id) {
            NSApplication.shared.applicationIconImage = image
            bundleID = id
        } else {
            NSApplication.shared.applicationIconImage = nil
        }
        syncBundleIcon(bundleID)
    }

    // MARK: 安装包图标

    /// 写 / 清安装包图标都排在这条串行队列上：连着换几次也按顺序落盘，决定（读记录、看 Icon\r）和动作之间不会被别的写插队。
    private static let bundleQueue = DispatchQueue(label: "io.github.hanson-zz.shiduo.bundle-icon", qos: .utility)
    private static var bundleGeneration = 0

    /// 把安装包的自定义图标对齐到 id（nil = 去掉自定义图标）。setIcon 在后台队列跑，结果回主线程更新设置里的小字。
    private static func syncBundleIcon(_ id: String?) {
        bundleGeneration += 1
        let generation = bundleGeneration
        let box = AltIconImageBox(image: id.flatMap { image(for: $0) })
        let path = Bundle.main.bundlePath
        bundleQueue.async {
            let outcome = AltAppIcons.performBundleSync(id: id, image: box.image, path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AltAppIcons.finishBundleSync(outcome, generation: generation)
                }
            }
        }
    }

    enum BundleSyncOutcome: Sendable {
        case unchanged
        case wrote
        case cleared
        case writeFailed
        case clearFailed
    }

    /// 后台队列上：按 BundleIconLogic 决定，写 / 清，成功了更新记录、提醒访达和程序坞。
    /// 注意：第一次往包里写图标会改动签名封印，个别系统版本上「完全磁盘访问权限」可能要重新打开一次。
    private nonisolated static func performBundleSync(id: String?, image: NSImage?, path: String) -> BundleSyncOutcome {
        let defaults = UserDefaults.standard
        let applied = defaults.string(forKey: BundleIconLogic.appliedKey)
        let hasCustom = bundleHasCustomIcon(path)
        switch BundleIconLogic.action(effective: id, applied: applied, bundleHasCustomIcon: hasCustom) {
        case .keep:
            return .unchanged
        case .write(let target):
            guard let image, NSWorkspace.shared.setIcon(image, forFile: path, options: []) else { return .writeFailed }
            defaults.set(target, forKey: BundleIconLogic.appliedKey)
            nudgeFinderAndDock(path)
            return .wrote
        case .clear:
            guard BundleIconLogic.clearNeedsWork(bundleHasCustomIcon: hasCustom) else {
                defaults.removeObject(forKey: BundleIconLogic.appliedKey)
                return .cleared
            }
            guard NSWorkspace.shared.setIcon(nil, forFile: path, options: []) else { return .clearFailed }
            defaults.removeObject(forKey: BundleIconLogic.appliedKey)
            nudgeFinderAndDock(path)
            return .cleared
        }
    }

    private static func finishBundleSync(_ outcome: BundleSyncOutcome, generation: Int) {
        // 中途又换了一次：以最后那次的结果为准。
        guard generation == bundleGeneration else { return }
        let status = AppIconBundleStatus.shared
        switch outcome {
        case .unchanged, .wrote:
            status.state = .ok
        case .cleared:
            status.state = .ok
            // 去掉自定义图标后让程序坞重新读一遍安装包里原来的图标。
            if effective == nil { NSApplication.shared.applicationIconImage = nil }
        case .writeFailed:
            status.state = .writeFailed
        case .clearFailed:
            status.state = .clearFailed
        }
    }

    /// 包根目录有「Icon\r」= 有自定义图标（setIcon 写的就是它；App 被更新 / 替换后会消失）。
    nonisolated static func bundleHasCustomIcon(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Icon\r"))
    }

    /// 告诉访达和程序坞图标变了：noteFileSystemChanged + 摸一下包的修改时间。不杀程序坞（killall Dock 太粗暴）。
    private nonisolated static func nudgeFinderAndDock(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        NSWorkspace.shared.noteFileSystemChanged(path)
    }
}

private struct AltIconImageBox: @unchecked Sendable {
    let image: NSImage?
}

/// 安装包图标写入结果：设置 › 外观 › 应用图标 下面那行小字看这个。
@MainActor
final class AppIconBundleStatus: ObservableObject {
    static let shared = AppIconBundleStatus()

    enum State: Equatable {
        /// 两处都换好了（或者没什么要换）。
        case ok
        /// 程序坞换了，安装包没写进去（没有写入权限）。
        case writeFailed
        /// 想还原成默认，但安装包里的自定义图标没删掉（没有写入权限）。
        case clearFailed
    }

    @Published fileprivate(set) var state: State = .ok

    private init() {}
}
