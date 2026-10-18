import OSLog
import AppKit
import Foundation

/// 暂存架上的一条记录：只记文件在哪（书签 + 路径），从不拷贝文件本身。
struct ShelfEntry: Codable, Equatable {
    /// URL.bookmarkData：文件被移动、改名后仍能找到。
    var bookmark: Data?
    /// 上次解析出的路径；书签解析失败时用来兜底。
    var path: String
    var added: Date
}

/// 暂存架：临时放一下的文件。主窗口的「暂存架」页面和 Pro 的悬浮暂存架共用这一份。
/// 记录保存在 ~/Library/Application Support/Shiduo/shelf.json，重新打开拾掇后还在。
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    /// 新放上来的排在前面。
    @Published private(set) var items: [FileItem] = []

    private var entries: [ShelfEntry] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var urls: [URL] { items.map(\.url) }

    static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Shiduo", isDirectory: true).appendingPathComponent("shelf.json")
    }

    private init() {
        // 演示模式不读也不写用户的暂存架。
        guard !Demo.isOn else { return }
        load()
        refresh()
    }

    // MARK: - 增删

    /// 放上暂存架。已经在上面的文件不会重复添加。返回新加了几个。
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        var known = Set(entries.map(\.path))
        var added: [ShelfEntry] = []
        for raw in urls {
            let url = raw.standardizedFileURL.resolvingSymlinksInPath()
            guard url.isFileURL, fm.fileExists(atPath: url.path), !known.contains(url.path) else { continue }
            known.insert(url.path)
            added.append(ShelfEntry(bookmark: Self.bookmark(for: url), path: url.path, added: Date()))
        }
        guard !added.isEmpty else { return 0 }
        entries.insert(contentsOf: added, at: 0)
        rebuildItems()
        save()
        return added.count
    }

    /// 只从暂存架上拿下来，文件本身不动。
    func remove(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let before = entries.count
        entries.removeAll { paths.contains($0.path) }
        guard entries.count != before else { return }
        rebuildItems()
        save()
    }

    func clear() {
        entries = []
        items = []
        save()
    }

    func contains(_ path: String) -> Bool {
        entries.contains { $0.path == path }
    }

    /// 文件被拾掇移走后，更新记录指向新位置。
    func relocate(from oldPath: String, to newURL: URL) {
        guard let index = entries.firstIndex(where: { $0.path == oldPath }) else { return }
        entries[index].path = newURL.path
        entries[index].bookmark = Self.bookmark(for: newURL)
        rebuildItems()
        save()
    }

    /// 重新解析书签：文件被移动或改名就跟过去，已经不存在（或进了废纸篓）的去掉。
    func refresh() {
        guard !Demo.isOn else { return }
        let fm = FileManager.default
        var changed = false
        var seen = Set<String>()
        var result: [ShelfEntry] = []
        for var entry in entries {
            var url: URL?
            if let data = entry.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                           relativeTo: nil, bookmarkDataIsStale: &stale) {
                    url = resolved.standardizedFileURL
                    if stale {
                        entry.bookmark = Self.bookmark(for: resolved)
                        changed = true
                    }
                }
            }
            if url == nil, fm.fileExists(atPath: entry.path) {
                url = URL(fileURLWithPath: entry.path)
                entry.bookmark = Self.bookmark(for: url!)
                changed = true
            }
            guard let url, fm.fileExists(atPath: url.path), !Self.isInTrash(url), seen.insert(url.path).inserted else {
                changed = true
                continue
            }
            if url.path != entry.path {
                entry.path = url.path
                changed = true
            }
            result.append(entry)
        }
        entries = result
        // 重新读每个文件的大小和修改时间：文件在别处被编辑、替换后，缩略图和总大小跟着更新。
        rebuildItems(fresh: true)
        if changed { save() }
    }

    /// 演示模式：直接放几个示例文件。
    func setDemo(_ list: [FileItem]) {
        entries = list.map { ShelfEntry(bookmark: nil, path: $0.path, added: Date()) }
        items = list
    }

    // MARK: - 存取

    /// fresh = true 时每个文件都重新读一遍（refresh 用）；否则沿用已有的 FileItem，只给新加的读。
    private func rebuildItems(fresh: Bool = false) {
        let current = fresh ? [:] : Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let rebuilt = entries.compactMap { entry in
            current[entry.path] ?? FileItem(url: URL(fileURLWithPath: entry.path))
        }
        // 没变就不发布，免得暂存架、刘海的界面白白重绘。
        if rebuilt != items { items = rebuilt }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let list = try? JSONDecoder().decode([ShelfEntry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        guard !Demo.isOn else { return }
        let url = Self.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func isInTrash(_ url: URL) -> Bool {
        url.path.contains("/.Trash/") || url.path.contains("/.Trashes/")
    }
}

// MARK: - 文件操作

/// 暂存架上的批量操作：移动、拷贝、压缩、共享。
enum ShelfActions {
    /// 选一个文件夹。取消时返回 nil。
    @MainActor
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    // 移动 / 拷贝在 ShelfTransfer（Views/ShelfPageView.swift）里：后台进行、有进度、能取消。

    /// 压缩成 ZIP（用系统自带的 ditto，和访达的「压缩」一样）。
    /// 放在第一个文件旁边；那里不能写时放进「下载」。返回 ZIP 的位置。
    static func zip(_ urls: [URL], multipleName: String) async -> URL? {
        guard let first = urls.first else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let fm = FileManager.default
            var folder = first.deletingLastPathComponent()
            if !fm.isWritableFile(atPath: folder.path) {
                folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            }
            if urls.count == 1 {
                let name = first.lastPathComponent + ".zip"
                let target = OrganizeEngine.uniqueURL(for: name, in: folder)
                return runDitto(source: first, target: target) ? target : nil
            }
            // 多个文件可能来自不同文件夹：先在临时目录里放一份（APFS 上是克隆，几乎不占空间），再整体压缩。
            let staging = fm.temporaryDirectory
                .appendingPathComponent("ShiduoShelf-\(UUID().uuidString)", isDirectory: true)
            let root = staging.appendingPathComponent(multipleName, isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                for url in urls {
                    let target = OrganizeEngine.uniqueURL(for: url.lastPathComponent, in: root)
                    try fm.copyItem(at: url, to: target)
                }
            } catch {
                AppLog.shelf.error("Shelf zip staging failed: \(AppLog.describe(error), privacy: .public)")
                return nil
            }
            let target = OrganizeEngine.uniqueURL(for: multipleName + ".zip", in: folder)
            return runDitto(source: root, target: target) ? target : nil
        }.value
    }

    private static func runDitto(source: URL, target: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, target.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                AppLog.shelf.error("ditto exited with status \(process.terminationStatus, privacy: .public)")
            }
            return process.terminationStatus == 0
        } catch {
            AppLog.shelf.error("ditto failed to start: \(AppLog.describe(error), privacy: .public)")
            return false
        }
    }

    /// 系统共享菜单（隔空投送、信息、邮件……），出现在鼠标位置。
    @MainActor
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        guard let view = window?.contentView, let window else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let rect = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
    // 隔空投送用 AirDropShare（Pro/FocusTimer.swift）：要一直持有系统分享服务，否则窗口一闪就没了。
}
