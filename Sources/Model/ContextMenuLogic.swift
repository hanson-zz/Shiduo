import Foundation

// 右键菜单补齐（B5，免费）里不碰界面、不碰磁盘的部分：单元测试直接编译这个文件。

/// 「打开方式 ▸」：默认 App 放最前，其他 App 去重、按名字排；多选时只列每个文件都能打开的。
enum OpenWithLogic {
    struct App: Hashable, Identifiable {
        let path: String
        let bundleID: String?
        let name: String
        var id: String { path }
    }

    /// 多选：每个文件都能打开的 App（按第一个文件的顺序）。只有一个文件时原样返回。
    static func commonApps(_ lists: [[App]]) -> [App] {
        guard let first = lists.first else { return [] }
        let rest = lists.dropFirst().map { list in Set(list.map(key)) }
        return first.filter { app in rest.allSatisfy { $0.contains(key(app)) } }
    }

    /// 多选：默认 App 一样时才算有默认 App。
    static func commonDefault(_ defaults: [App?]) -> App? {
        guard let first = defaults.first, let app = first else { return nil }
        return defaults.allSatisfy { $0.map(key) == key(app) } ? app : nil
    }

    /// 菜单里「默认」下面那一串：去掉默认 App，同一个 App 的多个版本（同 Bundle ID）只留第一个，按名字排。
    static func others(_ apps: [App], excluding defaultApp: App?) -> [App] {
        var seen = Set<String>()
        if let defaultApp { seen.insert(key(defaultApp)) }
        var result: [App] = []
        for app in apps where !seen.contains(key(app)) {
            seen.insert(key(app))
            result.append(app)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 同一个 App：有 Bundle ID 用 Bundle ID，没有用路径。
    static func key(_ app: App) -> String {
        if let id = app.bundleID, !id.isEmpty { return id.lowercased() }
        return app.path
    }
}

/// 「在终端打开」「在编辑器打开」认得的 App。
struct ExternalTool: Identifiable, Hashable {
    /// 主 Bundle ID（设置里存的就是它）。
    let id: String
    let name: String
    /// 同一个 App 的其他 Bundle ID（Sublime Text 3 / 4）。
    var otherIDs: [String] = []
    /// 能打开文件夹（文本编辑不能）。
    var opensFolders = true

    var bundleIDs: [String] { [id] + otherIDs }
}

enum ExternalToolCatalog {
    /// 终端：系统自带的「终端」永远在第一个。
    static let terminals: [ExternalTool] = [
        ExternalTool(id: "com.apple.Terminal", name: String(localized: "终端")),
        ExternalTool(id: "com.googlecode.iterm2", name: "iTerm"),
        ExternalTool(id: "dev.warp.Warp-Stable", name: "Warp", otherIDs: ["dev.warp.Warp"]),
        ExternalTool(id: "com.mitchellh.ghostty", name: "Ghostty"),
    ]

    /// 编辑器：没在设置里选时，用这里排在最前面、装了的那个（文本编辑兜底）。
    static let editors: [ExternalTool] = [
        ExternalTool(id: "com.microsoft.VSCode", name: "VS Code", otherIDs: ["com.microsoft.VSCodeInsiders"]),
        ExternalTool(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        ExternalTool(id: "dev.zed.Zed", name: "Zed", otherIDs: ["dev.zed.Zed-Preview"]),
        ExternalTool(id: "com.sublimetext.4", name: "Sublime Text", otherIDs: ["com.sublimetext.3"]),
        ExternalTool(id: "com.apple.dt.Xcode", name: "Xcode"),
        ExternalTool(id: "com.apple.TextEdit", name: String(localized: "文本编辑"), opensFolders: false),
    ]

    /// 设置里选的那个装着就用它；没选、或者已经卸载了，用列表里第一个装了的。
    static func resolve(preferred: String?, installed: Set<String>, in list: [ExternalTool]) -> ExternalTool? {
        let available = list.filter { tool in tool.bundleIDs.contains(where: installed.contains) }
        if let preferred, !preferred.isEmpty, let tool = available.first(where: { $0.id == preferred }) { return tool }
        return available.first
    }

    /// 在终端打开：文件夹就是它自己，文件用它所在的文件夹；去重、保持顺序。
    static func terminalFolders(_ entries: [(path: String, isDirectory: Bool)]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let folder = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
            if seen.insert(folder).inserted { result.append(folder) }
        }
        return result
    }

    /// 在编辑器打开：编辑器打不开文件夹时把文件夹拿掉。
    static func editorTargets(_ entries: [(path: String, isDirectory: Bool)], tool: ExternalTool) -> [String] {
        entries.filter { tool.opensFolders || !$0.isDirectory }.map(\.path)
    }
}

/// 新建的东西起名字：「名称」「名称 2」「名称 3」……（和访达、拾掇的拷贝一样，不覆盖）。
enum NewItemNaming {
    static func unique(_ base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 制作替身：「X 替身」（X 带扩展名，和访达一样），重名时「X 替身 2」。
    static func aliasName(for name: String, exists: (String) -> Bool) -> String {
        unique(String(localized: "\(name) 替身"), exists: exists)
    }

    /// 用所选项目新建文件夹。
    static func folderWithItemsName(exists: (String) -> Bool) -> String {
        unique(String(localized: "包含项目的新建文件夹"), exists: exists)
    }
}

/// 剪切 / 拷贝 / 粘贴文件（剪贴板里放的是系统的文件 URL，和访达互通）。
enum FileClipboardLogic {
    enum Mode: Equatable { case copy, move }

    /// ⌥⌘V 一律移动；⌘V 时，剪贴板还是拾掇「剪切」放进去的那一份（changeCount 对得上）就移动，否则拷贝
    /// （访达里 ⌘C 的文件在拾掇里 ⌘V 是拷贝，和访达一样）。
    static func mode(forceMove: Bool, cutChangeCount: Int?, currentChangeCount: Int) -> Mode {
        if forceMove { return .move }
        if let cut = cutChangeCount, cut == currentChangeCount { return .move }
        return .copy
    }

    struct Plan: Equatable {
        /// 要粘贴的路径。
        var paths: [String]
        /// 是目标文件夹自己或它的上层（不能粘进自己里面），跳过的个数。
        var skippedSelf: Int
        /// 移动时本来就在目标文件夹里，跳过的个数。
        var alreadyThere: Int
    }

    /// 已经解析掉符号链接的路径。
    static func plan(_ paths: [String], into folder: String, mode: Mode) -> Plan {
        let target = trimmed(folder)
        var plan = Plan(paths: [], skippedSelf: 0, alreadyThere: 0)
        for raw in paths {
            let path = trimmed(raw)
            if path == target || target.hasPrefix(path + "/") {
                plan.skippedSelf += 1
                continue
            }
            if mode == .move, (path as NSString).deletingLastPathComponent == target {
                plan.alreadyThere += 1
                continue
            }
            plan.paths.append(path)
        }
        return plan
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// 「直接删除」确认框里的文字。
enum DirectDeleteLogic {
    static func title(count: Int, firstName: String) -> String {
        count == 1
            ? String(localized: "确定要直接删除“\(firstName)”吗？")
            : String(localized: "确定要直接删除这 \(count) 个项目吗？")
    }

    /// bytes 为 nil：大小没算出来（文件夹太大），只说个数。
    static func detail(count: Int, bytes: Int64?) -> String {
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let head = size.map { String(localized: "共 \(count) 个项目，\($0)。") } ?? String(localized: "共 \(count) 个项目。")
        return head + String(localized: "不会进废纸篓，此操作无法撤销。只在 iCloud 云端的文件会被跳过。")
    }
}
