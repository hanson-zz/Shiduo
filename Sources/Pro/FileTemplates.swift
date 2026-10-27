import AppKit
import SwiftUI

// 拾掇 Pro：新建文件模板。空白处右键 / 文件菜单「新建文件 ▸」：内置几种空白文件，
// 加上「~/资源库/Application Support/Shiduo/Templates」里放的任何文件（放进去就出现在菜单里）。
// 新文件建在正在看的文件夹里，重名自动加 2，建好直接进入改名；⌥⌘N 再建一个上一次用的模板。

@MainActor
final class FileTemplateStore: ObservableObject {
    static let shared = FileTemplateStore()

    /// 模板文件夹里的文件（后台读，文件夹有变化时自动刷新）。
    @Published private(set) var userTemplates: [UserTemplate] = []

    static let lastKey = "fileTemplates.last"

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Shiduo", isDirectory: true).appendingPathComponent("Templates", isDirectory: true)
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var activationObserver: NSObjectProtocol?

    private init() {
        refresh()
        startWatching()
        // 切回拾掇时也刷新一次（文件夹是后来才建的、监视没挂上时也不漏）。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                FileTemplateStore.shared.refresh()
                FileTemplateStore.shared.startWatching()
            }
        }
    }

    func refresh() {
        let folder = Self.folder
        Task {
            let list = await Task.detached(priority: .utility) { FileTemplateLogic.listTemplates(in: folder) }.value
            if list != userTemplates { userTemplates = list }
        }
    }

    /// 监视模板文件夹：往里放 / 删文件时菜单马上跟着变。
    private func startWatching() {
        guard watcher == nil else { return }
        let fd = Darwin.open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let store = FileTemplateStore.shared
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    store.watcher?.cancel()
                    store.watcher = nil
                }
                store.refresh()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    /// 建好模板文件夹（不存在时）。
    nonisolated static func ensureFolder() throws -> URL {
        let url = folder
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 「管理模板…」：在访达里打开模板文件夹。
    func manage() {
        Task {
            let url = await Task.detached { try? Self.ensureFolder() }.value
            guard let url else { return }
            startWatching()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    /// 「把所选存为模板」：拷一份到模板文件夹（重名自动加 2）。
    func saveAsTemplates(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (names: [String], failed: Int) in
                guard let folder = try? Self.ensureFolder() else { return ([], urls.count) }
                let fm = FileManager.default
                var names: [String] = []
                var failed = 0
                for url in urls {
                    let name = FileTemplateLogic.uniqueName(url.lastPathComponent) {
                        fm.fileExists(atPath: folder.appendingPathComponent($0).path)
                    }
                    do {
                        try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
                        names.append(name)
                    } catch {
                        failed += 1
                    }
                }
                return (names, failed)
            }.value
            startWatching()
            refresh()
            guard let store = LibraryStore.shared else { return }
            if result.names.count == 1, let name = result.names.first {
                store.showToast(String(localized: "已存为模板：\(name)"))
            } else if !result.names.isEmpty {
                store.showToast(String(localized: "已存为模板：\(result.names.count) 个文件"))
            }
            if result.failed > 0 {
                store.alertMessage = String(localized: "\(result.failed) 个文件没能存为模板（可能没有权限）。")
            }
        }
    }

    // MARK: 新建

    var lastChoice: FileTemplateLogic.Choice {
        FileTemplateLogic.choice(forKey: UserDefaults.standard.string(forKey: Self.lastKey), userNames: userTemplates.map(\.name))
    }

    var lastTitle: String {
        switch lastChoice {
        case .builtIn(let template): return template.title
        case .user(let name): return name
        }
    }

    /// ⌥⌘N：再建一个上一次用的模板。
    func createLast(in store: LibraryStore) {
        switch lastChoice {
        case .builtIn(let template): create(.builtIn(template), in: store)
        case .user(let name):
            if let template = userTemplates.first(where: { $0.name == name }) {
                create(.user(template), in: store)
            } else {
                create(.builtIn(.text), in: store)
            }
        }
    }

    enum Source {
        case builtIn(BuiltInTemplate)
        case user(UserTemplate)
    }

    /// 在正在看的文件夹里建一个新文件，然后原地改名；⌘Z 撤销（移到废纸篓）。
    func create(_ source: Source, in store: LibraryStore) {
        guard LicenseManager.shared.isPro else {
            NSApp.activate(ignoringOtherApps: true)
            LicenseManager.shared.showPaywall = true
            return
        }
        guard let folderPath = store.currentFolder, store.activeQuery == nil, store.archiveSession == nil else {
            store.showToast(String(localized: "先打开一个文件夹，再新建文件"))
            return
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let key: String
        switch source {
        case .builtIn(let template): key = FileTemplateLogic.key(builtIn: template)
        case .user(let template): key = FileTemplateLogic.key(user: template.name)
        }
        UserDefaults.standard.set(key, forKey: Self.lastKey)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                let fm = FileManager.default
                let wanted: String
                switch source {
                case .builtIn(let template): wanted = template.fileName
                case .user(let template): wanted = FileTemplateLogic.expand(template.name)
                }
                let name = FileTemplateLogic.uniqueName(wanted) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                let target = folder.appendingPathComponent(name)
                do {
                    switch source {
                    case .builtIn(let template):
                        try template.contents.write(to: target, options: .withoutOverwriting)
                        if template.isExecutable {
                            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                        }
                    case .user(let template):
                        try fm.copyItem(at: template.url, to: target)
                        // 拷出来的是新文件：修改时间换成现在，排在「最近」前面。
                        try? fm.setAttributes([.modificationDate: Date(), .creationDate: Date()], ofItemAtPath: target.path)
                    }
                    return .success(target)
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let url):
                store.insertCreatedFile(url)
            case .failure(let error):
                store.alertMessage = error.localizedDescription
            }
        }
    }
}

extension LibraryStore {
    /// 新建好的文件放进列表、选中、进入改名，登记 ⌘Z（移到废纸篓）。
    func insertCreatedFile(_ url: URL) {
        registerCreatedFileUndo(url)
        filesChangedTick += 1
        guard let item = FileItem(url: url), currentFolder == url.deletingLastPathComponent().standardizedFileURL.path else {
            refreshQuietly()
            return
        }
        remember([item])
        if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        selectedIDs = [item.id]
        inlineRenamePath = item.path
    }

    private func registerCreatedFileUndo(_ url: URL) {
        guard let manager = FileUndoCenter.shared.undoManager else { return }
        manager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                store.forget(paths: [url.path])
                store.refreshQuietly()
            }
        }
        manager.setActionName(String(localized: "新建文件"))
    }
}

/// 「新建文件 ▸」子菜单（空白处右键、文件菜单共用）。没解锁 Pro 时标题带「· Pro」和小锁，点哪一项都弹升级面板。
struct NewFileMenu: View {
    @ObservedObject private var templates = FileTemplateStore.shared
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        Menu {
            ForEach(BuiltInTemplate.allCases) { template in
                Button {
                    run { templates.create(.builtIn(template), in: $0) }
                } label: {
                    Label(template.title, systemImage: template.symbol)
                }
            }
            if !templates.userTemplates.isEmpty {
                Divider()
                ForEach(templates.userTemplates) { template in
                    Button {
                        run { templates.create(.user(template), in: $0) }
                    } label: {
                        Label(template.name, systemImage: "star")
                    }
                }
            }
            Divider()
            Button {
                if license.isPro { templates.manage() } else { showPaywall() }
            } label: {
                Label("管理模板…", systemImage: "gearshape")
            }
        } label: {
            if license.isPro {
                Text("新建文件")
            } else {
                Label {
                    Text("新建文件") + Text(verbatim: "  · Pro")
                } icon: {
                    Image(systemName: "lock.fill")
                }
            }
        }
    }

    private func run(_ action: @escaping @MainActor (LibraryStore) -> Void) {
        guard license.isPro else {
            showPaywall()
            return
        }
        guard let store = LibraryStore.shared else { return }
        // 等菜单收起、焦点回到列表再建（要原地改名）。
        DispatchQueue.main.async { action(store) }
    }

    private func showPaywall() {
        NSApp.activate(ignoringOtherApps: true)
        LicenseManager.shared.showPaywall = true
    }
}
