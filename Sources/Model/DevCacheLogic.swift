import Foundation

/// 智能清理「开发缓存」：只认下面白名单里的位置，白名单以外的一概不碰。
/// 这些都是开发工具自己会重新生成或重新下载的缓存，删了最多是下次编译 / 安装慢一点。
/// 纯逻辑 + 读文件夹，单元测试用临时文件夹当个人文件夹。
enum DevCacheLogic {
    enum Mode: Equatable, Sendable {
        /// 整个文件夹算一项（里面全是缓存）。
        case whole
        /// 里面的每一项各算一项（例如 DerivedData 里每个项目一份）。
        case children
        /// 下两层里、最后修改早于 N 天的各算一项（Xcode 归档：Archives/日期/App.xcarchive）。
        case grandchildrenOlderThan(days: Int)
    }

    struct Entry: Equatable, Sendable {
        /// 相对个人文件夹的路径。
        let relativePath: String
        /// 界面上显示的来源名字。
        let label: String
        let mode: Mode
    }

    /// 白名单。顺序就是界面上的顺序。
    static var entries: [Entry] {
        [
            Entry(relativePath: "Library/Developer/Xcode/DerivedData", label: "Xcode DerivedData", mode: .children),
            Entry(relativePath: "Library/Developer/Xcode/Archives",
                  label: String(localized: "Xcode 半年前的归档"), mode: .grandchildrenOlderThan(days: 180)),
            Entry(relativePath: "Library/Developer/Xcode/iOS DeviceSupport", label: "iOS DeviceSupport", mode: .children),
            Entry(relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", label: "watchOS DeviceSupport", mode: .children),
            Entry(relativePath: "Library/Developer/Xcode/tvOS DeviceSupport", label: "tvOS DeviceSupport", mode: .children),
            Entry(relativePath: "Library/Developer/Xcode/visionOS DeviceSupport", label: "visionOS DeviceSupport", mode: .children),
            Entry(relativePath: "Library/Developer/CoreSimulator/Caches", label: String(localized: "模拟器缓存"), mode: .whole),
            Entry(relativePath: "Library/Caches/Homebrew", label: "Homebrew", mode: .whole),
            Entry(relativePath: "Library/Caches/pip", label: "pip", mode: .whole),
            Entry(relativePath: "Library/Caches/Yarn", label: "Yarn", mode: .whole),
            Entry(relativePath: ".yarn/berry/cache", label: "Yarn", mode: .whole),
            Entry(relativePath: ".npm/_cacache", label: "npm", mode: .whole),
            Entry(relativePath: "Library/pnpm/store", label: "pnpm", mode: .whole),
            Entry(relativePath: "Library/Caches/CocoaPods", label: "CocoaPods", mode: .whole),
            Entry(relativePath: ".gradle/caches", label: "Gradle", mode: .whole),
            Entry(relativePath: "Library/Caches/go-build", label: String(localized: "Go 编译缓存"), mode: .whole),
            Entry(relativePath: ".cargo/registry/cache", label: "Cargo", mode: .whole),
            Entry(relativePath: "Library/Caches/org.swift.swiftpm", label: "Swift Package Manager", mode: .whole),
        ]
    }

    struct Candidate: Equatable, Sendable {
        let path: String
        /// 来源（Xcode DerivedData、npm……）。
        let label: String
    }

    /// 去掉末尾的「/」、解开「.」「..」，比较用。
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 这个路径是不是白名单里的某个位置本身或在它下面。移到废纸篓之前再核一次。
    static func isWhitelisted(_ path: String, home: String) -> Bool {
        guard !path.isEmpty, !home.isEmpty else { return false }
        // 带「..」的一律不认（就算解开后落在白名单里，也说明来路不正常）。
        if path.split(separator: "/").contains("..") { return false }
        let p = normalize(path)
        for entry in entries {
            let root = normalize((home as NSString).appendingPathComponent(entry.relativePath))
            if p == root || p.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// 是真正的文件夹（不是替身 / 符号链接）。
    static func isRealDirectory(_ path: String, fileManager fm: FileManager) -> Bool {
        guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    /// 不是符号链接的项目（文件或文件夹）。
    private static func isRealItem(_ path: String, fileManager fm: FileManager) -> Bool {
        guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return false }
        return type != .typeSymbolicLink
    }

    private static func visibleChildren(_ path: String, fileManager fm: FileManager) -> [String] {
        // 读不了（没有完全磁盘访问权限等）就当没有。
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
            .map { (path as NSString).appendingPathComponent($0) }
    }

    private static func modified(_ path: String, fileManager fm: FileManager) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// 在个人文件夹里找白名单上真实存在、有内容的缓存。白名单位置本身是替身的整个跳过。
    static func candidates(home: String, now: Date = Date(), fileManager fm: FileManager = .default,
                           isCancelled: () -> Bool = { false }) -> [Candidate] {
        var result: [Candidate] = []
        var seen = Set<String>()
        func add(_ path: String, _ label: String) {
            let p = normalize(path)
            guard isWhitelisted(p, home: home), seen.insert(p).inserted else { return }
            result.append(Candidate(path: p, label: label))
        }
        for entry in entries {
            if isCancelled() { break }
            let root = (home as NSString).appendingPathComponent(entry.relativePath)
            guard isRealDirectory(root, fileManager: fm) else { continue }
            switch entry.mode {
            case .whole:
                if !((try? fm.contentsOfDirectory(atPath: root)) ?? []).isEmpty { add(root, entry.label) }
            case .children:
                for child in visibleChildren(root, fileManager: fm) where isRealItem(child, fileManager: fm) {
                    add(child, entry.label)
                }
            case .grandchildrenOlderThan(let days):
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                for child in visibleChildren(root, fileManager: fm) where isRealDirectory(child, fileManager: fm) {
                    for grand in visibleChildren(child, fileManager: fm) where isRealItem(grand, fileManager: fm) {
                        if let date = modified(grand, fileManager: fm), date < cutoff { add(grand, entry.label) }
                    }
                }
            }
        }
        return result
    }
}

/// 「邮件」打开附件时存的副本（Mail Downloads）。原邮件里还能再打开。
enum MailDownloadsLogic {
    static func roots(home: String) -> [String] {
        [
            (home as NSString).appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            (home as NSString).appendingPathComponent("Library/Mail Downloads"),
        ]
    }

    /// 是不是在某个 Mail Downloads 里面（不含文件夹本身）。
    static func isInside(_ path: String, home: String) -> Bool {
        if path.split(separator: "/").contains("..") { return false }
        let p = DevCacheLogic.normalize(path)
        return roots(home: home).contains { p.hasPrefix(DevCacheLogic.normalize($0) + "/") }
    }

    struct Candidate: Equatable, Sendable {
        let path: String
        /// 显示的名字：附件通常放在一个随机编号的文件夹里，显示里面第一个文件的名字。
        let title: String
    }

    /// 每个 Mail Downloads 第一层的项目。skipContainer：没有完全磁盘访问权限时不碰「邮件」的容器（会弹系统提示）。
    static func candidates(home: String, skipContainer: Bool, fileManager fm: FileManager = .default) -> [Candidate] {
        var result: [Candidate] = []
        for (index, root) in roots(home: home).enumerated() {
            if index == 0 && skipContainer { continue }
            guard DevCacheLogic.isRealDirectory(root, fileManager: fm),
                  let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(name)
                guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
                      type != .typeSymbolicLink else { continue }
                var title = name
                if type == .typeDirectory,
                   let first = (try? fm.contentsOfDirectory(atPath: path))?.filter({ !$0.hasPrefix(".") }).sorted().first {
                    title = first
                }
                result.append(Candidate(path: path, title: title))
            }
        }
        return result
    }
}
