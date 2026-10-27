import AppKit
import SwiftUI

/// 剪切 ⌘X / 拷贝 ⌘C / 粘贴 ⌘V / 粘贴并移动 ⌥⌘V（免费）。
/// 剪贴板里放的是系统的文件 URL：拾掇里拷贝的在访达里能粘贴，访达里拷贝的在拾掇里也能粘贴。
/// 「剪切」只是记下这一份剪贴板（changeCount）：在拾掇里粘贴时移动；在访达里粘贴还是拷贝（访达自己没有剪切，要移动用 ⌥⌘V）。
@MainActor
enum FileClipboard {
    /// 拾掇「剪切」时剪贴板的 changeCount（剪贴板被别的内容换掉后就对不上了）。
    private static var cutChangeCount: Int?

    private static var board: NSPasteboard { .general }

    static func write(_ items: [FileItem], cut: Bool) {
        let urls = items.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        board.clearContents()
        board.writeObjects(urls)
        cutChangeCount = cut ? board.changeCount : nil
        guard let store = LibraryStore.shared else { return }
        if cut {
            store.showToast(items.count == 1
                ? String(localized: "已剪切“\(items[0].name)”，到别的文件夹粘贴（⌘V）就会移过去")
                : String(localized: "已剪切 \(items.count) 个项目，到别的文件夹粘贴（⌘V）就会移过去"))
        } else {
            store.showToast(items.count == 1
                ? String(localized: "已拷贝“\(items[0].name)”，在拾掇或访达里都能粘贴")
                : String(localized: "已拷贝 \(items.count) 个项目，在拾掇或访达里都能粘贴"))
        }
    }

    /// 剪贴板里的文件（只要本机上还在的）。
    static var fileURLs: [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var hasFiles: Bool {
        board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// 剪贴板里有几个文件（菜单标题用）。
    static var fileCount: Int {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (board.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.count ?? 0
    }

    /// 粘贴到 folder。forceMove：⌥⌘V。
    static func paste(into folder: URL, forceMove: Bool) {
        guard let store = LibraryStore.shared else { return }
        let urls = fileURLs
        guard !urls.isEmpty else {
            store.showToast(String(localized: "剪贴板里没有文件"))
            return
        }
        let mode = FileClipboardLogic.mode(forceMove: forceMove, cutChangeCount: cutChangeCount,
                                           currentChangeCount: board.changeCount)
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let plan = FileClipboardLogic.plan(urls.map(real), into: real(folder), mode: mode)
        if plan.paths.isEmpty {
            if plan.skippedSelf > 0 {
                store.showToast(String(localized: "不能把文件夹粘贴到它自己里面"))
            } else if plan.alreadyThere > 0 {
                store.showToast(String(localized: "这些项目已经在这个文件夹里了"))
            }
            return
        }
        guard !ShelfTransfer.shared.isRunning else {
            store.showToast(String(localized: "还有文件在移动，请稍等"))
            return
        }
        ShelfTransfer.shared.start(plan.paths.map { URL(fileURLWithPath: $0) }, to: folder, copy: mode == .copy, store: store)
        // 剪切的东西移走以后，再粘贴一次就是拷贝（文件已经不在原处，自然什么也不做）。
        if mode == .move { cutChangeCount = nil }
    }
}

/// 「编辑」「文件」菜单里的文件命令：处理最前面那个窗口里选中的文件（和 ⌘⌫ 用同一份登记）。
/// 正在编辑 / 选着文字时（搜索框、改名框、简介里的文字……），剪切、拷贝、粘贴照旧交给文字。
@MainActor
enum FileCommandRouter {
    /// 键盘焦点在文字上（输入框或可以选中的文字）。
    static var textHasFocus: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    static var selection: [FileItem] { TrashCommandCenter.shared.currentItems() }

    /// 粘贴到哪里：最前面是主窗口、正在浏览一个文件夹（不是搜索结果）时，就是这个文件夹。
    static var pasteFolder: URL? {
        guard let window = NSApp.keyWindow, MainWindow.isMain(window),
              let store = LibraryStore.shared, store.activeQuery == nil,
              let folder = store.currentFolder, !store.isInlineRenaming else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    private static func forward(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    static func cut() {
        let items = selection
        if textHasFocus || items.isEmpty { forward(#selector(NSText.cut(_:))); return }
        FileClipboard.write(items, cut: true)
    }

    static func copy() {
        let items = selection
        if textHasFocus || items.isEmpty { forward(#selector(NSText.copy(_:))); return }
        FileClipboard.write(items, cut: false)
    }

    static func paste() {
        if !textHasFocus, let folder = pasteFolder, FileClipboard.hasFiles {
            FileClipboard.paste(into: folder, forceMove: false)
        } else {
            forward(#selector(NSText.paste(_:)))
        }
    }

    static func pasteAndMove() {
        guard !textHasFocus, let folder = pasteFolder else { return }
        FileClipboard.paste(into: folder, forceMove: true)
    }

    static func copyPath() {
        let items = selection
        guard !textHasFocus, !items.isEmpty else { return }
        FileActions.copyPaths(items)
        LibraryStore.shared?.showToast(items.count == 1 ? String(localized: "已拷贝路径") : String(localized: "已拷贝 \(items.count) 个路径"))
    }

    static func selectAll() {
        forward(#selector(NSResponder.selectAll(_:)))
    }
}

/// 「编辑」菜单：剪切 / 拷贝 / 粘贴 / 粘贴并移动 / 拷贝路径 / 全选（替换系统那一组，文字照样能剪切拷贝粘贴）。
/// 「文件」菜单：用所选项目新建文件夹、制作替身、打开方式之外的几项。
struct FileCommands: Commands {
    @ObservedObject var center: TrashCommandCenter
    /// 拾掇 Pro 自定义快捷键：改了以后菜单马上换。
    @ObservedObject private var shortcuts = ShortcutStore.shared
    let store: LibraryStore

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("剪切") { FileCommandRouter.cut() }
                .keyboardShortcut(.cut)
            Button("拷贝") { FileCommandRouter.copy() }
                .keyboardShortcut(.copyItems)
            Button("粘贴") { FileCommandRouter.paste() }
                .keyboardShortcut(.paste)
            Button("粘贴并移动") { FileCommandRouter.pasteAndMove() }
                .keyboardShortcut(.pasteAndMove)
            Button("拷贝路径") { FileCommandRouter.copyPath() }
                .keyboardShortcut(.copyPath)
                .disabled(!center.canTrash)
            Button("全选") { FileCommandRouter.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("用所选项目新建文件夹") { store.newFolderWithSelection(FileCommandRouter.selection) }
                .keyboardShortcut(.newFolderWithSelection)
                .disabled(!center.canTrash || store.currentFolder == nil || store.activeQuery != nil || store.isInlineRenaming)
            Button("复制") { store.duplicate(FileCommandRouter.selection) }
                .keyboardShortcut(.duplicate)
                .disabled(!center.canTrash)
            Button("制作替身") { store.makeAliases(FileCommandRouter.selection) }
                .keyboardShortcut(.makeAlias)
                .disabled(!center.canTrash)
            Divider()
            Button("在终端打开") {
                let items = FileCommandRouter.selection
                if items.isEmpty, let folder = store.currentFolder {
                    ExternalApps.openInTerminal([(folder, true)])
                } else {
                    ExternalApps.openInTerminal(items)
                }
            }
            .disabled(!center.canTrash && store.currentFolder == nil)
            Button("在编辑器打开") {
                let items = FileCommandRouter.selection
                if items.isEmpty, let folder = store.currentFolder {
                    ExternalApps.openFolderInEditor(URL(fileURLWithPath: folder, isDirectory: true))
                } else {
                    ExternalApps.openInEditor(items)
                }
            }
            .disabled(!center.canTrash && store.currentFolder == nil)
            Button("计算哈希") {
                if let item = FileCommandRouter.selection.first(where: { !$0.isDirectory }) { store.showHash(item) }
            }
            .disabled(!center.canTrash)
        }
    }
}

// MARK: - 新建文件夹、替身、哈希

extension LibraryStore {
    /// ⌃⌘N 用所选项目新建文件夹：在当前文件夹里建「包含项目的新建文件夹」，把选中的移进去，然后原地改名。
    /// 一步 ⌘Z：移回原处，新文件夹空了就移到废纸篓。
    func newFolderWithSelection(_ list: [FileItem]) {
        guard let folder = currentFolder, activeQuery == nil, !list.isEmpty else { return }
        let parent = URL(fileURLWithPath: folder, isDirectory: true)
        // 只收当前文件夹里的（和访达一样）。
        let inside = list.filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path }
        guard !inside.isEmpty else { return }
        if refuseProtected(inside.map(\.path)) { return }
        let sources = inside.map(\.url)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (folder: URL?, pairs: [FileUndoLogic.PathPair], error: String?) in
                let fm = FileManager.default
                let name = NewItemNaming.folderWithItemsName { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
                let target = parent.appendingPathComponent(name, isDirectory: true)
                do {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                } catch {
                    return (nil, [], error.localizedDescription)
                }
                var pairs: [FileUndoLogic.PathPair] = []
                var failure: String?
                for url in sources {
                    let destination = target.appendingPathComponent(url.lastPathComponent)
                    do {
                        try fm.moveItem(at: url, to: destination)
                        pairs.append(FileUndoLogic.PathPair(from: url.path, to: destination.path))
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                return (target, pairs, failure)
            }.value
            guard let created = result.folder else {
                alertMessage = result.error
                return
            }
            if let action = FileUndoCenter.shared.registerPaths(result.pairs, name: String(localized: "用所选项目新建文件夹"), toast: nil) {
                action.createdFolders = [created.path]
            }
            forget(paths: Set(result.pairs.map(\.from)))
            FolderSizeStore.shared.noteChanged([created.path])
            if let item = FileItem(url: created) {
                remember([item])
                if !items.contains(where: { $0.id == item.id }) { items.append(item) }
                selectedIDs = [item.id]
                inlineRenamePath = item.path
            }
            if let error = result.error {
                alertMessage = String(localized: "有的项目没能移进新文件夹：\(error)")
            }
        }
    }

    /// ⌃⌘A 制作替身：在原文件旁边建访达替身「X 替身」（和访达的替身一样，原文件移走了也找得到）。⌘Z 把替身移到废纸篓。
    func makeAliases(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        let sources = list.map(\.url)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (made: [URL], failed: [String]) in
                let fm = FileManager.default
                var made: [URL] = []
                var failed: [String] = []
                for url in sources {
                    let parent = url.deletingLastPathComponent()
                    let name = NewItemNaming.aliasName(for: url.lastPathComponent) {
                        fm.fileExists(atPath: parent.appendingPathComponent($0).path)
                    }
                    let alias = parent.appendingPathComponent(name)
                    do {
                        let data = try url.bookmarkData(options: .suitableForBookmarkFile,
                                                        includingResourceValuesForKeys: nil, relativeTo: nil)
                        try URL.writeBookmarkData(data, to: alias)
                        made.append(alias)
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                }
                return (made, failed)
            }.value
            if !result.made.isEmpty {
                let made = result.made
                if let manager = FileUndoCenter.shared.undoManager {
                    manager.registerUndo(withTarget: self) { store in
                        MainActor.assumeIsolated { store.moveToTrash(made.compactMap { FileItem(url: $0) }) }
                    }
                    manager.setActionName(String(localized: "制作替身"))
                }
                let newItems = made.compactMap { FileItem(url: $0) }
                remember(newItems)
                if let folder = currentFolder, activeQuery == nil {
                    let here = newItems.filter { $0.url.deletingLastPathComponent().path == URL(fileURLWithPath: folder).path }
                    for item in here where !items.contains(where: { $0.id == item.id }) { items.append(item) }
                    if !here.isEmpty { selectedIDs = Set(here.map(\.id)) }
                }
                showToast(made.count == 1 ? String(localized: "已制作替身：\(made[0].lastPathComponent)")
                                          : String(localized: "已制作 \(made.count) 个替身"))
            }
            if !result.failed.isEmpty {
                alertMessage = String(localized: "\(result.failed.count) 个项目没能制作替身（文件夹可能不能写入）：")
                    + result.failed.prefix(5).joined(separator: String(localized: "、"))
            }
        }
    }

    /// ⌘D 复制：在原处拷贝一份（同名自动叫「名称 2」），走移动 / 拷贝的进度卡片，⌘Z 把副本移到废纸篓。
    /// 选中的在不同文件夹里（搜索结果）时，只复制和第一个在同一个文件夹里的。
    func duplicate(_ list: [FileItem]) {
        guard let first = list.first else { return }
        let parent = first.url.deletingLastPathComponent()
        let same = list.filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path }
        transferDropped(same.map(\.url), into: parent, copy: true)
    }

    /// 计算哈希：打开简介、滚到「校验值」并开始算。
    func showHash(_ item: FileItem) {
        guard !item.isDirectory else { return }
        MainWindow.show(then: { [weak self] in
            guard let self else { return }
            self.remember([item])
            self.selectedIDs = [item.id]
            self.inspectorMode = .info
            self.showInspector = true
            HashRequest.shared.request(item.path)
        })
    }
}

/// 「计算哈希」：简介里的校验值看到这个请求就滚过去、开始算。
@MainActor
final class HashRequest: ObservableObject {
    static let shared = HashRequest()
    /// 还没被简介接走的请求（简介可能还没出现）。
    @Published private(set) var pendingPath: String?
    /// 还没滚过去的请求（简介滚到「校验值」后清掉）。
    private(set) var scrollPath: String?
    @Published private(set) var tick = 0

    func request(_ path: String) {
        pendingPath = path
        scrollPath = path
        tick &+= 1
    }

    func takeScroll(_ path: String) -> Bool {
        guard scrollPath == path else { return false }
        scrollPath = nil
        return true
    }

    /// 简介里这个文件的校验值接走请求：返回 true 表示要开始算。
    func take(_ path: String) -> Bool {
        guard pendingPath == path else { return false }
        pendingPath = nil
        return true
    }
}
