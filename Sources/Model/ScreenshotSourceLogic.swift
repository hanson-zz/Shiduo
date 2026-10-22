import Foundation

/// 截图工具的存放文件夹：装了哪些截图工具、它们存到哪里（纯逻辑，单元测试覆盖）。
/// 真正去查 App 是否安装、读偏好设置的是 ScreenshotSourceDetector（只读 ~/Library/Preferences 和工具自己的配置文件，
/// 不碰别的 App 的沙盒容器，不会弹权限询问）。
enum ScreenshotSourceLogic {
    /// 一个已知的截图工具。
    struct Tool: Sendable, Equatable {
        var id: String
        /// 设置里显示的名字（品牌名不翻译；微信 / 飞书 / 钉钉在界面层再本地化）。
        var name: String
        var bundleIDs: [String]
        /// bundle id 查不到时，按 App 名字在 /Applications、~/Applications 里找。
        var appNames: [String]
        /// 默认的专用存放文件夹（相对个人文件夹），不管设置怎么改都算。
        var defaultFolders: [String] = []
        /// 偏好设置里可能存着存放位置的键（在 bundleIDs 各自的 plist 里找）；另外还会按键名猜。
        var folderKeys: [String] = []
        /// 工具自己的 ini 配置文件（相对个人文件夹）。
        var iniFiles: [String] = []
        /// 专用文件夹里不算截图的文件名（比如缩略图）。
        var excludedNames: [String] = []
    }

    /// 已知的截图工具。bundle id 来自各工具的安装包 / 源码；不确定的同时按 App 名字找。
    static let tools: [Tool] = [
        Tool(id: "snipaste", name: "Snipaste", bundleIDs: ["com.Snipaste", "com.snipaste.Snipaste"],
             appNames: ["Snipaste"], iniFiles: [".snipaste/config.ini"]),
        Tool(id: "cleanshot", name: "CleanShot X",
             bundleIDs: ["pl.maketheweb.cleanshotx", "pl.maketheweb.cleanshotx-setapp"],
             appNames: ["CleanShot X"], folderKeys: ["exportPath", "savePath", "screenshotsPath"]),
        Tool(id: "xnip", name: "Xnip", bundleIDs: ["com.xnipapp.xnip", "com.xnip.Xnip"], appNames: ["Xnip"]),
        Tool(id: "ishot", name: "iShot", bundleIDs: ["cn.better365.ishot", "cn.better365.ishotpro"],
             appNames: ["iShot", "iShot Pro"]),
        Tool(id: "pixpin", name: "PixPin", bundleIDs: ["com.pixpin.pixpin", "com.pixpin.app"], appNames: ["PixPin"]),
        Tool(id: "shottr", name: "Shottr", bundleIDs: ["cc.ffitch.shottr"], appNames: ["Shottr"]),
        // QuickShot（cclank/quickshot）：「快速保存」固定存到「下载」，文件名 quickshot-日期_时间-毫秒-序号.png，靠文件名认。
        Tool(id: "quickshot", name: "QuickShot", bundleIDs: ["com.quickshot.app"], appNames: ["QuickShot"]),
        // Snapok（thinkany-ai/snapok）：截图库默认在 ~/Library/Application Support/Snapok/History/<编号>/original.png，
        // 旁边的 thumbnail.png 是缩略图；可在它的设置里换位置（偏好设置 history.location）。
        Tool(id: "snapok", name: "Snapok", bundleIDs: ["ai.thinkany.snapok", "ai.thinkany.snapok.dev", "ai.snapok.mac"],
             appNames: ["Snapok", "Snapok Dev"],
             defaultFolders: ["Library/Application Support/Snapok/History", "Library/Application Support/Snapok Dev/History"],
             folderKeys: ["history.location"], excludedNames: ["thumbnail.png"]),
        Tool(id: "wechat", name: "微信", bundleIDs: ["com.tencent.xinWeChat"], appNames: ["WeChat", "微信"]),
        Tool(id: "qq", name: "QQ", bundleIDs: ["com.tencent.qq"], appNames: ["QQ"]),
        Tool(id: "feishu", name: "飞书", bundleIDs: ["com.bytedance.lark.Feishu", "com.electron.lark", "com.larksuite.larkApp"],
             appNames: ["Feishu", "飞书", "Lark"]),
        Tool(id: "dingtalk", name: "钉钉", bundleIDs: ["com.alibaba.DingTalkMac"], appNames: ["DingTalk", "钉钉"]),
    ]

    /// 系统截图（⇧⌘3 / ⇧⌘4 / ⇧⌘5）的设置：com.apple.screencapture 的 location。
    static let systemDomain = "com.apple.screencapture"
    static let systemLocationKey = "location"

    /// 一个算作截图的文件夹。
    struct Folder: Sendable, Equatable, Codable {
        var path: String
        var excludedNames: [String] = []
    }

    // MARK: 文件夹

    /// 把偏好设置里的值变成绝对路径：支持 /…、~/…、file:// 链接；别的都不要。
    static func normalizedPath(_ raw: String, home: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        } else if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = (home as NSString).appendingPathComponent(String(text.dropFirst(2)))
        }
        guard text.hasPrefix("/") else { return nil }
        let standardized = (text as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// 是不是专门放截图的文件夹。桌面、下载、文稿、图片、个人文件夹这类普通文件夹（以及它们的上级）不算，
    /// 否则那里所有图片都会被当成截图——这些地方的截图靠文件名和系统标记认。
    static func isDedicated(_ path: String, home: String) -> Bool {
        let p = path.lowercased()
        let h = home.lowercased()
        let general = ["", "/Desktop", "/Downloads", "/Documents", "/Pictures", "/Movies", "/Music",
                       "/Library", "/Library/Mobile Documents", "/Library/Mobile Documents/com~apple~CloudDocs"]
            .map { (h + $0.lowercased()) }
        if general.contains(p) { return false }
        // 个人文件夹的上级、根目录、/Users、/Volumes 本身。
        if h.hasPrefix(p + "/") || p == "/" || p == "/users" || p == "/volumes" { return false }
        return true
    }

    /// 文件在不在某个截图文件夹里（任意深度），而且不是被排除的文件名。不区分大小写（APFS 默认如此）。
    static func folder(containing path: String, in folders: [Folder]) -> Folder? {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        return folders.first { folder in
            let base = folder.path.lowercased()
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard lower.hasPrefix(prefix) else { return false }
            return !folder.excludedNames.contains { $0.lowercased() == name }
        }
    }

    static func isInScreenshotFolder(_ path: String, folders: [Folder]) -> Bool {
        folder(containing: path, in: folders) != nil
    }

    /// 去重、去掉不是专用的文件夹、去掉被别的文件夹包含的子文件夹（保留上级）。
    static func cleaned(_ folders: [Folder], home: String) -> [Folder] {
        var result: [Folder] = []
        for folder in folders where isDedicated(folder.path, home: home) {
            let lower = folder.path.lowercased()
            if let i = result.firstIndex(where: { $0.path.lowercased() == lower }) {
                result[i].excludedNames = Array(Set(result[i].excludedNames + folder.excludedNames)).sorted()
                continue
            }
            result.append(folder)
        }
        return result.filter { inner in
            !result.contains { outer in
                outer.path.lowercased() != inner.path.lowercased()
                    && inner.path.lowercased().hasPrefix(outer.path.lowercased() + "/")
            }
        }
    }

    // MARK: 读配置

    /// 从偏好设置字典里找存放位置：先看指定的键，再按键名猜（含 save / export / output / screenshot / capture
    /// 之一，又含 path / dir / folder / location 之一），值必须像路径。
    static func folders(fromPreferences prefs: [String: Any], keys: [String], home: String) -> [String] {
        var found: [String] = []
        func add(_ value: Any?) {
            if let text = value as? String, let path = normalizedPath(text, home: home), !found.contains(path) {
                found.append(path)
            } else if let url = value as? URL, url.isFileURL, !found.contains(url.path) {
                found.append(url.path)
            }
        }
        for key in keys { add(prefs[key]) }
        for key in prefs.keys.sorted() where !keys.contains(key) && looksLikeFolderKey(key) {
            add(prefs[key])
        }
        return found
    }

    static func looksLikeFolderKey(_ key: String) -> Bool {
        let k = key.lowercased()
        let what = ["save", "export", "output", "screenshot", "capture"].contains { k.contains($0) }
        let place = ["path", "dir", "folder", "location"].contains { k.contains($0) }
        return what && place
    }

    /// 解析 ini（Snipaste 的 config.ini 等）：返回 [小节名.键名: 值]，小节名、键名都转小写。
    static func parseINI(_ text: String) -> [String: String] {
        var section = ""
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[section.isEmpty ? key : section + "." + key] = value
        }
        return result
    }

    /// 从 ini 里找存放位置（按键名猜，见 looksLikeFolderKey；Snipaste 的 [Output] 小节优先）。
    static func folders(fromINI text: String, home: String) -> [String] {
        let values = parseINI(text)
        var found: [String] = []
        let keys = values.keys.sorted { a, b in
            let ao = a.hasPrefix("output."), bo = b.hasPrefix("output.")
            return ao != bo ? ao : a < b
        }
        for key in keys {
            let bare = key.split(separator: ".").last.map(String.init) ?? key
            guard looksLikeFolderKey(bare) || key.hasPrefix("output.") && bare.hasSuffix("path"),
                  let raw = values[key], let path = normalizedPath(raw, home: home), !found.contains(path) else { continue }
            found.append(path)
        }
        return found
    }
}

/// 当前识别到的截图文件夹（ScreenshotSourceDetector 在后台更新；FileItem 分类时读）。
enum ScreenshotFolders {
    private static let lock = NSLock()
    private static var folders: [ScreenshotSourceLogic.Folder] = []

    static var current: [ScreenshotSourceLogic.Folder] {
        lock.lock(); defer { lock.unlock() }
        return folders
    }

    static func update(_ new: [ScreenshotSourceLogic.Folder]) {
        lock.lock(); defer { lock.unlock() }
        folders = new
    }
}
