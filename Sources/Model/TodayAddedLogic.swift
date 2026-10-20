import Foundation

/// 首页「今天新增」用到的纯逻辑：哪些文件算今天进来的、按什么类型分组、放在哪个位置。
/// 只依赖 Foundation 和 FileCategory，单元测试也会编译它。
protocol TodayAddable {
    var path: String { get }
    var name: String { get }
    var size: Int64 { get }
    var typeTree: [String] { get }
    var added: Date? { get }
    /// 文件夹，或者 .app 以外的包（.rtfd、.photoslibrary……）。
    var isDirectory: Bool { get }
}

/// 「今天新增」弹窗里的类型筛选。比资料库分类多一个「安装包」和「其他」。
enum TodayKind: String, CaseIterable, Identifiable, Hashable {
    case images
    case documents
    case installers
    case videos
    case music
    case archives
    case apps
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return String(localized: "图片")
        case .documents: return String(localized: "文稿")
        case .installers: return String(localized: "安装包")
        case .videos: return String(localized: "视频")
        case .music: return String(localized: "音乐")
        case .archives: return String(localized: "压缩包")
        case .apps: return String(localized: "应用程序")
        case .other: return String(localized: "其他")
        }
    }
}

/// 文件在哪个常用位置（弹窗每一行的「下载 · 1.2 MB」）。
enum TodayLocation: Hashable {
    case downloads
    case desktop
    case documents
    case pictures
    case movies
    case music
    case applications
    case home
    /// 其他文件夹：直接用所在文件夹的名字。
    case folder(String)

    var title: String {
        switch self {
        case .downloads: return String(localized: "下载")
        case .desktop: return String(localized: "桌面")
        case .documents: return String(localized: "文稿")
        case .pictures: return String(localized: "图片")
        case .movies: return String(localized: "视频")
        case .music: return String(localized: "音乐")
        case .applications: return String(localized: "应用程序")
        case .home: return String(localized: "个人文件夹")
        case .folder(let name): return name
        }
    }
}

enum TodayAddedLogic {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    /// 今天（本地日历）的起止：[今天 0 点, 明天 0 点)。
    static func dayRange(containing now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    /// 下一个 0 点（跨天时刷新用）。
    static func nextMidnight(after now: Date, calendar: Calendar = .current) -> Date {
        dayRange(containing: now, calendar: calendar).end
    }

    static func kind(name: String, typeTree: [String]) -> TodayKind {
        let ext = (name as NSString).pathExtension.lowercased()
        let tree = Set(typeTree)
        if installerExtensions.contains(ext) || tree.contains("com.apple.installer-package-archive") {
            return .installers
        }
        guard let category = FileCategory.classify(typeTree: typeTree) else {
            return ext == "app" ? .apps : .other
        }
        switch category {
        case .images: return .images
        case .videos: return .videos
        case .music: return .music
        case .documents: return .documents
        case .archives: return .archives
        case .apps: return .apps
        case .recents: return .other
        }
    }

    static func kind<T: TodayAddable>(of item: T) -> TodayKind {
        kind(name: item.name, typeTree: item.typeTree)
    }

    /// 和资料库一样只看用户自己的文件：隐藏文件、~/Library、缓存、应用包和其他包里面的东西都不算。
    static func isUserPath(_ path: String, home: String) -> Bool {
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        let inHome = path.hasPrefix(homePrefix)
        let inApplications = path.hasPrefix("/Applications/")
        guard inHome || inApplications else { return false }
        let relative = inHome ? String(path.dropFirst(homePrefix.count)) : String(path.dropFirst("/Applications/".count))
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        if inHome, parts.first == "Library" { return false }
        for (index, part) in parts.enumerated() {
            if part.hasPrefix(".") { return false }
            let lower = part.lowercased()
            if ["caches", "cache", "node_modules", "deriveddata", "pods"].contains(lower) { return false }
            // 包里面的文件（Foo.app/Contents/…、Bar.photoslibrary/…）。
            let isLast = index == parts.count - 1
            if !isLast, let dot = lower.lastIndex(of: ".") {
                let ext = lower[lower.index(after: dot)...]
                if ["app", "bundle", "framework", "photoslibrary", "xcassets", "plugin", "kext", "rtfd", "pages", "numbers", "key", "musiclibrary", "tvlibrary"].contains(String(ext)) {
                    return false
                }
            }
        }
        return true
    }

    static func location(of path: String, home: String) -> TodayLocation {
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix("/Applications/") { return .applications }
        let parent = (path as NSString).deletingLastPathComponent
        guard path.hasPrefix(homePrefix) else { return .folder((parent as NSString).lastPathComponent) }
        let relative = String(path.dropFirst(homePrefix.count))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count <= 1 { return .home }
        switch parts[0] {
        case "Downloads": return .downloads
        case "Desktop": return .desktop
        case "Documents": return .documents
        case "Pictures": return .pictures
        case "Movies": return .movies
        case "Music": return .music
        case "Applications": return .applications
        default: return .folder((parent as NSString).lastPathComponent)
        }
    }

    /// 「其他」类型的文件只在下载和桌面里才算（直接放在里面的），
    /// 免得 git clone 一个工程、解压一个源码包就冒出几千个「今天新增」。
    static func countsOther(path: String, home: String) -> Bool {
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(homePrefix) else { return false }
        let parts = path.dropFirst(homePrefix.count).split(separator: "/")
        return parts.count == 2 && (parts[0] == "Downloads" || parts[0] == "Desktop")
    }

    /// 这个文件算不算「今天新增」（日期已经在查询里限定时 range 可以不传）。
    static func isRelevant<T: TodayAddable>(_ item: T, home: String, range: (start: Date, end: Date)? = nil) -> Bool {
        if let range {
            guard let added = item.added, added >= range.start, added < range.end else { return false }
        }
        guard !item.isDirectory, !item.name.hasPrefix("."), isUserPath(item.path, home: home) else { return false }
        if kind(of: item) == .other { return countsOther(path: item.path, home: home) }
        return true
    }

    /// 过滤、去重，按加入时间从新到旧排好。
    static func filter<T: TodayAddable>(_ items: [T], home: String, range: (start: Date, end: Date)) -> [T] {
        var seen = Set<String>()
        return items
            .filter { isRelevant($0, home: home, range: range) && seen.insert($0.path).inserted }
            .sorted {
                let a = $0.added ?? .distantPast, b = $1.added ?? .distantPast
                return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    struct Summary: Equatable {
        var count: Int
        var bytes: Int64
        /// 有文件的类型和个数：多的在前，一样多时按 TodayKind 的顺序。
        var kinds: [KindCount]
    }

    struct KindCount: Equatable, Identifiable {
        var kind: TodayKind
        var count: Int
        var id: TodayKind { kind }
    }

    static func summary<T: TodayAddable>(_ items: [T]) -> Summary {
        var counts: [TodayKind: Int] = [:]
        var bytes: Int64 = 0
        for item in items {
            counts[kind(of: item), default: 0] += 1
            bytes += max(item.size, 0)
        }
        let order = TodayKind.allCases
        let kinds = counts.filter { $0.value > 0 }
            .map { KindCount(kind: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
            }
        return Summary(count: items.count, bytes: bytes, kinds: kinds)
    }

    /// 按类型筛选（nil = 全部）。
    static func items<T: TodayAddable>(_ items: [T], of kind: TodayKind?) -> [T] {
        guard let kind else { return items }
        return items.filter { self.kind(of: $0) == kind }
    }
}
