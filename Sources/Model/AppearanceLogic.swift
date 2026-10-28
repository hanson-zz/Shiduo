import Foundation

// 设置 › 外观 的纯逻辑部分（不依赖界面，单元测试直接编译这个文件）：
// 存什么、怎么存（带默认值、容错解码）、字号范围、主题色、缩略图什么时候生成、透视文件夹挑哪几张、备选应用图标的排序。
// 浅色 / 深色（AppAppearance，键 appearanceMode）和文件夹图标风格（FolderWallIconStyle，键 folderWallIconStyle）
// 以前就有，键名不变，不放进这里。

/// 主题色：默认（跟随系统强调色）+ 8 种颜色。只改拾掇自己的强调色 / 控件颜色，不改系统设置。
enum AccentChoice: String, CaseIterable, Codable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var id: Self { self }

    /// 颜色值（sRGB 0…1）。默认是 nil：跟随「系统设置 › 外观 › 强调色」。
    var rgb: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .system: return nil
        case .blue: return (0.04, 0.48, 1.00)
        case .purple: return (0.58, 0.32, 0.86)
        case .pink: return (0.97, 0.31, 0.62)
        case .red: return (0.93, 0.25, 0.25)
        case .orange: return (0.98, 0.55, 0.12)
        case .yellow: return (0.98, 0.76, 0.10)
        case .green: return (0.30, 0.72, 0.30)
        case .graphite: return (0.55, 0.55, 0.58)
        }
    }

    /// 十六进制 RRGGBB（测试和调试用）；默认没有。
    var hex: String? {
        guard let c = rgb else { return nil }
        return String(format: "%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
    }
}

/// 侧边栏图标大小。
enum SidebarIconSize: String, CaseIterable, Codable, Identifiable {
    case small
    case medium
    case large

    var id: Self { self }

    /// 彩色方块图标（「位置」那几行）的边长。
    var badgeSide: Double {
        switch self {
        case .small: return 16
        case .medium: return 20
        case .large: return 24
        }
    }
}

/// 「缩略图起始尺寸」：图标比这个小时不生成预览图，只显示通用图标（省 Quick Look 的开销）。
/// 0 = 不限（任何尺寸都生成，和以前一样）。
enum ThumbnailStartSize: Int, CaseIterable, Codable, Identifiable {
    case any = 0
    case p32 = 32
    case p64 = 64
    case p128 = 128

    var id: Self { self }
}

/// 文件列表字号：11–16，默认 13（系统列表的默认字号）。
enum ListFontSize {
    static let range: ClosedRange<Double> = 11...16
    static let defaultSize: Double = 13

    /// 超出范围的值拉回范围里，非整数取最近的整数（滑块一格一号），NaN 当默认。
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSize }
        return min(max(value.rounded(), range.lowerBound), range.upperBound)
    }

    /// 列表里名字前面的小图标跟着字号变：13 号 → 20 点（以前的固定值）。
    static func listIconSide(_ fontSize: Double) -> Double {
        clamp(fontSize) + 7
    }

    /// 图标视图里名字的字号：比列表小一号（13 → 12，以前的 .callout）。
    static func gridNameSize(_ fontSize: Double) -> Double {
        clamp(fontSize) - 1
    }
}

/// 外观设置里新加的几项，存成一份 JSON（UserDefaults「appearance.settings」）。
/// 解码容错：缺了的项目、认不出的值都用默认值，字号拉回 11–16；以后加新项目，旧数据照样能读。
struct AppearanceSettings: Equatable, Codable {
    static let key = "appearance.settings"

    var accent: AccentChoice = .system
    var listFontSize: Double = ListFontSize.defaultSize
    var sidebarColorIcons = true
    var sidebarIconSize: SidebarIconSize = .medium
    var alwaysPreviewMedia = true
    var thumbnailStartSize: ThumbnailStartSize = .any
    /// 透视文件夹：默认关（每个文件夹多读一次目录，用户自己打开）。
    var peekFolders = false
    /// 备选应用图标的 id；nil = 默认图标。
    var appIcon: String?

    init() {}

    enum CodingKeys: String, CodingKey {
        case accent, listFontSize, sidebarColorIcons, sidebarIconSize, alwaysPreviewMedia, thumbnailStartSize, peekFolders, appIcon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings.defaults
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            // 类型不对（比如手改坏了）也不让整份读失败：这一项用默认值。
            guard let v = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return v
        }
        let accentRaw: String? = value(String.self, .accent)
        accent = accentRaw.flatMap(AccentChoice.init(rawValue:)) ?? d.accent
        let size: Double? = value(Double.self, .listFontSize)
        listFontSize = ListFontSize.clamp(size ?? d.listFontSize)
        let colorIcons: Bool? = value(Bool.self, .sidebarColorIcons)
        sidebarColorIcons = colorIcons ?? d.sidebarColorIcons
        let sidebarRaw: String? = value(String.self, .sidebarIconSize)
        sidebarIconSize = sidebarRaw.flatMap(SidebarIconSize.init(rawValue:)) ?? d.sidebarIconSize
        let always: Bool? = value(Bool.self, .alwaysPreviewMedia)
        alwaysPreviewMedia = always ?? d.alwaysPreviewMedia
        let startRaw: Int? = value(Int.self, .thumbnailStartSize)
        thumbnailStartSize = startRaw.flatMap(ThumbnailStartSize.init(rawValue:)) ?? d.thumbnailStartSize
        let peek: Bool? = value(Bool.self, .peekFolders)
        peekFolders = peek ?? d.peekFolders
        let icon: String? = value(String.self, .appIcon)
        appIcon = AltAppIconLogic.isValidID(icon) ? icon : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accent.rawValue, forKey: .accent)
        try c.encode(ListFontSize.clamp(listFontSize), forKey: .listFontSize)
        try c.encode(sidebarColorIcons, forKey: .sidebarColorIcons)
        try c.encode(sidebarIconSize.rawValue, forKey: .sidebarIconSize)
        try c.encode(alwaysPreviewMedia, forKey: .alwaysPreviewMedia)
        try c.encode(thumbnailStartSize.rawValue, forKey: .thumbnailStartSize)
        try c.encode(peekFolders, forKey: .peekFolders)
        try c.encodeIfPresent(appIcon, forKey: .appIcon)
    }

    static let defaults = AppearanceSettings()

    /// 从存的数据读；没有或读不了时是默认值。
    static func decode(_ data: Data?) -> AppearanceSettings {
        guard let data, let value = try? JSONDecoder().decode(AppearanceSettings.self, from: data) else { return defaults }
        return value
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

/// 什么时候给文件生成预览图（缩略图）。
enum ThumbnailPolicy {
    /// 文件夹里超过这么多项时算「大文件夹」：关掉「总是预览图片和视频」后，大文件夹里一律用通用图标。
    static let bigFolderCount = 1000

    /// - isMedia: 图片或视频
    /// - iconSide: 图标边长（点）
    /// - folderItemCount: 当前列表有多少项（不知道时传 0）
    static func loadsThumbnail(isMedia: Bool, iconSide: Double, folderItemCount: Int, settings: AppearanceSettings) -> Bool {
        if isMedia && settings.alwaysPreviewMedia { return true }
        if !settings.alwaysPreviewMedia && folderItemCount > bigFolderCount { return false }
        return iconSide >= Double(settings.thumbnailStartSize.rawValue)
    }
}

/// 透视文件夹：从文件夹第一层里挑最新的几张图片 / 视频叠在文件夹图标上。
enum PeekFolderLogic {
    struct Entry: Equatable {
        var name: String
        var isMedia: Bool
        var isDirectory: Bool
        var date: Date
    }

    /// 最多显示几张。
    static let limit = 3
    /// 一个文件夹最多看这么多项就停（超大的文件夹不整个读完）。
    static let scanCap = 2000
    /// 图标小于这个边长（点）不透视：太小看不清，也省得读目录。
    static let minIconSide: Double = 28

    /// 最新的几张：只要图片 / 视频，跳过隐藏文件和子文件夹；按日期从新到旧，同一时间按名字（访达规则）排，结果稳定。
    static func pickNewest(_ entries: [Entry], limit: Int = PeekFolderLogic.limit) -> [Entry] {
        guard limit > 0 else { return [] }
        let candidates = entries.filter { $0.isMedia && !$0.isDirectory && !$0.name.hasPrefix(".") }
        let sorted = candidates.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }

    /// 扩展名是不是图片 / 视频（读目录时还没取类型，先按扩展名粗筛；App 里再用 UTType 确认）。
    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "jxl", "psd", "svg", "raw", "dng", "cr2", "cr3", "nef", "arw",
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mts",
    ]

    static func isMediaName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && mediaExtensions.contains(ext)
    }
}

/// 备选应用图标：App 里 AltAppIcons 文件夹的 <id>.png，内置的按固定顺序排，以后新放进来的按名字排在后面。
enum AltAppIconLogic {
    /// 内置几款的顺序：小熊猫日常色 → 带 Pro 角标的 → 节日 → 笑脸小电脑。
    /// 早先的占位 violet / navy / cobalt 已经删了：存着这几个的用户 resolve 时文件不在 → 自动回到默认图标。
    static let builtInOrder = [
        "panda-cream",
        "panda-night",
        "panda-royal-pro",
        "panda-gold-pro",
        "panda-ruby-pro",
        "panda-prism-pro",
        "panda-blue-pro",
        "panda-yellow-pro",
        "panda-red-pro",
        "panda-purple-pro",
        "panda-rainbow-pro",
        "panda-navy-pro",
        "panda-bronze-pro",
        "panda-wine-pro",
        "panda-grape-pro",
        "panda-aurora-pro",
        "panda-halloween",
        "panda-christmas",
        "mac-cream",
        "mac-teal",
        "mac-sky-pro",
        "mac-navy",
        "mac-red-pro",
        "mac-rainbow-pro",
        "mac-leaf",
        "mac-lavender",
        "mac-halloween",
        "mac-christmas",
    ]

    /// id 只许小写字母、数字、- 和 _（文件名就是 id，免得怪名字）。
    static func isValidID(_ id: String?) -> Bool {
        guard let id, !id.isEmpty, id.count <= 40 else { return false }
        let letters: ClosedRange<Unicode.Scalar> = "a"..."z"
        let digits: ClosedRange<Unicode.Scalar> = "0"..."9"
        return id.unicodeScalars.allSatisfy { letters.contains($0) || digits.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// 文件名 → 排好序的 id 列表：只认 .png，名字不合规的、「default」（默认图标是安装包里的那个）跳过，去重。
    static func ids(fromFileNames names: [String]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for name in names {
            let ns = name as NSString
            guard ns.pathExtension.lowercased() == "png" else { continue }
            let id = ns.deletingPathExtension
            guard isValidID(id), id != "default", seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids.sorted { a, b in
            let ia = builtInOrder.firstIndex(of: a) ?? Int.max
            let ib = builtInOrder.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }
    }

    /// 存着的选择还能不能用：没选、或者那个文件已经不在了 → 用默认图标（nil）。
    static func resolve(_ chosen: String?, available: [String], isPro: Bool) -> String? {
        guard isPro, let chosen, available.contains(chosen) else { return nil }
        return chosen
    }
}
