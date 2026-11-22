import AppKit
import Combine
import Foundation

/// 拾掇 Pro「工作区」放行规则只写在这里：以后想改成免费，把 requiresPro 改成 false 就行。
/// 免费用户也能看到侧边栏入口、空工作区的引导；执行「添加文件夹」「新建工作区」时弹付费页。
@MainActor
enum WorkspaceAccess {
    static let feature: ProFeature = .workspace
    static let requiresPro = true

    static var unlocked: Bool { !requiresPro || LicenseManager.shared.isPro }

    /// 能用就返回 true；不能用时弹出拾掇 Pro 介绍页。
    static func require() -> Bool {
        if unlocked { return true }
        ProPaywall.open()
        return false
    }
}

/// 工作区：配置、来源状态、后台扫描、快捷操作。主窗口里所有标签 / 栏共用这一份。
/// 配置存在 UserDefaults 的 "workspaces" 键（见 WorkspaceLogic.swift），演示模式不读也不写。
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    nonisolated static let defaultsKey = "workspaces"

    @Published private(set) var workspaces: [Workspace] = []
    /// 每个来源此刻的状态（来源 id → 状态）。
    @Published private(set) var availability: [UUID: WorkspaceSourceAvailability] = [:]
    /// 这次运行里扫描出来的结果（分段标签里的文件列表只在这里，不存盘）。
    @Published private(set) var live: [UUID: WorkspaceScanner.Result] = [:]
    /// 正在扫描的来源。
    @Published private(set) var scanning: Set<UUID> = []
    /// 正在打包的工作区。
    @Published private(set) var zipping: UUID?
    /// 页面上要进入改名状态的工作区（双击标题、菜单「重命名」）。
    @Published var renamingInline: UUID?

    private var file = WorkspacesFile()
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var scanFlags: [UUID: WorkspaceCancelFlag] = [:]
    private var zipFlag: WorkspaceCancelFlag?
    private var observers: [NSObjectProtocol] = []

    private init() {
        if !Demo.isOn {
            file = WorkspaceCodec.decode(UserDefaults.standard.data(forKey: Self.defaultsKey))
            workspaces = file.workspaces
            save()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WorkspaceStore.shared.volumesChanged() }
            })
        }
        refreshAvailability()
    }

    // MARK: - 读

    func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    func state(_ source: WorkspaceSource) -> WorkspaceSourceAvailability {
        availability[source.id] ?? .online(path: source.path)
    }

    /// 统计：这次扫过的用新的，没扫过（或离线）用缓存。
    func stats(_ source: WorkspaceSource) -> WorkspaceSourceStats? {
        live[source.id]?.stats ?? source.stats
    }

    func totals(_ workspace: Workspace) -> WorkspaceTotals {
        WorkspaceLogic.totals(workspace.sources.map { stats($0) })
    }

    func isScanning(_ workspace: Workspace) -> Bool {
        workspace.sources.contains { scanning.contains($0.id) }
    }

    /// 能用的来源（在线的）。
    func onlineSources(_ workspace: Workspace) -> [(source: WorkspaceSource, path: String)] {
        workspace.sources.compactMap { source in state(source).path.map { (source, $0) } }
    }

    /// 最近文件（跨来源，新的在前）。
    func recentFiles(_ workspace: Workspace, limit: Int = 12) -> [WorkspaceFileRow] {
        rows(workspace, limit: limit) { stats($0)?.recent }
    }

    /// 分段标签里某一类的文件（kind 为 nil 时是第一层子文件夹；只有这次运行扫过的来源有）。
    func files(_ workspace: Workspace, kind: WorkspaceFileKind?, limit: Int = 300) -> [WorkspaceFileRow] {
        rows(workspace, limit: limit) { source in
            self.live[source.id].map { result in kind.map { result.byKind[$0] ?? [] } ?? result.folders }
        }
    }

    private func rows(_ workspace: Workspace, limit: Int, list: (WorkspaceSource) -> [WorkspaceFileEntry]?) -> [WorkspaceFileRow] {
        var owner: [String: WorkspaceSource] = [:]
        var lists: [[WorkspaceFileEntry]] = []
        for source in workspace.sources {
            guard let entries = list(source) else { continue }
            for entry in entries { owner[entry.path] = source }
            lists.append(entries)
        }
        return WorkspaceLogic.mergeRecent(lists, limit: limit).compactMap { entry in
            owner[entry.path].map { WorkspaceFileRow(entry: entry, source: $0) }
        }
    }

    // MARK: - 工作区

    @discardableResult
    func create(name: String? = nil) -> UUID? {
        guard WorkspaceAccess.require() else { return nil }
        let title = name.flatMap(WorkspaceLogic.sanitizedName) ?? WorkspaceLogic.newName(existing: workspaces.map(\.name))
        let workspace = Workspace(name: title, colorIndex: workspaces.count % FolderPalette.colors.count)
        workspaces.append(workspace)
        save()
        return workspace.id
    }

    func rename(_ id: UUID, to raw: String) {
        guard let name = WorkspaceLogic.sanitizedName(raw) else { return }
        update(id) { $0.name = name }
    }

    func setColor(_ id: UUID, _ index: Int) {
        update(id) { $0.colorIndex = index }
    }

    func setSymbol(_ id: UUID, _ symbol: String) {
        update(id) { $0.symbol = symbol }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        workspaces = WorkspaceLogic.move(workspaces, from: source, to: destination)
        save()
    }

    /// 删除工作区：只删配置和引用，来源文件夹和里面的文件一个都不动。
    func delete(_ id: UUID) {
        guard let workspace = self.workspace(id) else { return }
        for source in workspace.sources { cancelScan(source.id) }
        if zipping == id { zipFlag?.cancel() }
        workspaces.removeAll { $0.id == id }
        for source in workspace.sources {
            availability[source.id] = nil
            live[source.id] = nil
        }
        save()
    }

    /// 删除前确认（侧边栏右键、⋯ 菜单、工作区设置共用）。删了返回 true。
    @discardableResult
    func confirmDelete(_ id: UUID) -> Bool {
        guard let workspace = self.workspace(id) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "删除工作区“\(workspace.name)”？")
        alert.informativeText = String(localized: "只删除这个工作区和它记住的位置，原来的文件夹和文件都不会动。")
        alert.addButton(withTitle: String(localized: "删除工作区"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        delete(id)
        return true
    }

    /// 改名输入框（侧边栏右键「重命名…」）。
    func promptRename(_ id: UUID) {
        guard let workspace = self.workspace(id) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "重命名工作区")
        let field = NSTextField(string: workspace.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rename(id, to: field.stringValue)
    }

    private func update(_ id: UUID, _ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&workspaces[index])
        save()
    }

    private func save() {
        guard !Demo.isOn else { return }
        file.workspaces = workspaces
        file.seededDefault = true
        if let data = WorkspaceCodec.encode(file) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - 来源

    /// 选文件夹加进工作区（要 Pro）。返回给用户看的一句话（没加任何东西且没有问题时为 nil）。
    func chooseAndAddSources(to id: UUID) -> String? {
        guard WorkspaceAccess.require() else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "添加到工作区")
        panel.message = String(localized: "选一个或几个文件夹。工作区只记住位置，不移动、不复制原文件。")
        guard panel.runModal() == .OK else { return nil }
        return addSources(panel.urls, to: id)
    }

    /// 把文件夹加成来源（拖到侧边栏工作区上也走这里）。
    @discardableResult
    func addSources(_ urls: [URL], to id: UUID) -> String? {
        guard WorkspaceAccess.require(), var workspace = self.workspace(id) else { return nil }
        var added: [WorkspaceSource] = []
        var problems: [String] = []
        for url in urls {
            guard LibraryStore.isBrowsableFolder(url) else {
                problems.append(String(localized: "「\(url.lastPathComponent)」不是文件夹"))
                continue
            }
            if let problem = WorkspaceLogic.addProblem(path: url.path, existing: workspace.sources + added) {
                switch problem {
                case .alreadyAdded(let name): problems.append(String(localized: "「\(name)」已经在这个工作区里了"))
                case .insideExisting(let name): problems.append(String(localized: "「\(url.lastPathComponent)」已经包含在「\(name)」里"))
                case .notFolder: problems.append(String(localized: "「\(url.lastPathComponent)」不是文件夹"))
                }
                continue
            }
            let volume = FolderBackupStore.volumeInfo(containing: url)
            added.append(WorkspaceLogic.makeSource(url: url, volume: volume))
        }
        guard !added.isEmpty else { return problems.first }
        workspace.sources.append(contentsOf: added)
        update(id) { $0.sources = workspace.sources }
        for source in added {
            availability[source.id] = .online(path: source.path)
            scan(source)
        }
        let message = String(localized: "已添加 \(added.count) 个文件夹（只记位置，原文件不动）")
        return problems.isEmpty ? message : message + "；" + problems.joined(separator: "；")
    }

    /// 从工作区移除一个来源：只删引用，文件夹本身不动。
    func removeSource(_ sourceID: UUID, from id: UUID) {
        cancelScan(sourceID)
        update(id) { $0.sources.removeAll { $0.id == sourceID } }
        availability[sourceID] = nil
        live[sourceID] = nil
    }

    // MARK: - 状态 / 扫描

    /// 重新判定所有来源的状态：书签跟着改名 / 移动走，外接硬盘看接没接上。
    func refreshAvailability() {
        let mounted = Demo.isOn ? [] : FolderBackupStore.mountedVolumes()
        var changed = false
        for wi in workspaces.indices {
            for si in workspaces[wi].sources.indices {
                let source = workspaces[wi].sources[si]
                var resolved: String?
                if let data = source.bookmark, !Demo.isOn {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) {
                        resolved = url.path
                        if stale, FileManager.default.fileExists(atPath: url.path) {
                            workspaces[wi].sources[si].bookmark = try? url.bookmarkData()
                            changed = true
                        }
                    }
                }
                let state = WorkspaceLogic.availability(of: source, resolvedPath: resolved, mounted: mounted, isFolder: Self.isFolder)
                if let path = state.path, path != source.path {
                    // 文件夹改名 / 挪了地方：跟过去（显示的名字也跟着变）。
                    workspaces[wi].sources[si].path = path
                    if source.isOnExternalVolume, let volume = mounted.first(where: { WorkspaceLogic.matches(source, volume: $0) }) {
                        workspaces[wi].sources[si].relativePath = FolderBackupLogic.relativePath(of: path, inVolume: volume.mountPath)
                    }
                    changed = true
                }
                if availability[source.id] != state { availability[source.id] = state }
            }
        }
        if changed { save() }
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 插拔硬盘：重新判定状态，刚接上的硬盘上的来源重新扫描。
    private func volumesChanged() {
        let before = availability
        refreshAvailability()
        for workspace in workspaces {
            for source in workspace.sources {
                let now = state(source)
                if now.isOnline, before[source.id]?.isOnline != true { scan(source) }
                if !now.isOnline { cancelScan(source.id) }
            }
        }
    }

    /// 打开工作区页面时：判定状态，在线但这次还没扫过的来源在后台扫一遍（force：全部重扫）。
    func refresh(_ id: UUID, force: Bool = false) {
        guard !Demo.isOn || force else { return }
        refreshAvailability()
        guard let workspace = self.workspace(id) else { return }
        for source in workspace.sources where state(source).isOnline {
            if force || live[source.id] == nil { scan(source) }
        }
    }

    /// 停下这个工作区正在进行的扫描（离开页面、点「停止」）。
    func cancelScans(_ id: UUID) {
        guard let workspace = self.workspace(id) else { return }
        for source in workspace.sources { cancelScan(source.id) }
    }

    private func cancelScan(_ sourceID: UUID) {
        scanFlags[sourceID]?.cancel()
        scanFlags[sourceID] = nil
        scanTasks[sourceID]?.cancel()
        scanTasks[sourceID] = nil
        scanning.remove(sourceID)
    }

    /// 后台扫一个来源（大目录不卡界面；可以取消）；结果写进缓存。
    func scan(_ source: WorkspaceSource) {
        guard let path = state(source).path else { return }
        cancelScan(source.id)
        let flag = WorkspaceCancelFlag()
        scanFlags[source.id] = flag
        scanning.insert(source.id)
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let sourceID = source.id
        scanTasks[sourceID] = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                WorkspaceScanner.scan(root: root, isCancelled: { flag.isCancelled })
            }.value
            let store = WorkspaceStore.shared
            guard store.scanFlags[sourceID] === flag else { return }
            store.scanFlags[sourceID] = nil
            store.scanTasks[sourceID] = nil
            store.scanning.remove(sourceID)
            guard let result, !flag.isCancelled else { return }
            store.live[sourceID] = result
            store.storeStats(result.stats, for: sourceID)
        }
    }

    private func storeStats(_ stats: WorkspaceSourceStats, for sourceID: UUID) {
        for wi in workspaces.indices {
            if let si = workspaces[wi].sources.firstIndex(where: { $0.id == sourceID }) {
                workspaces[wi].sources[si].stats = stats
                save()
                return
            }
        }
    }

    // MARK: - 演示

    /// 演示模式：直接放几个工作区（来源在临时目录里，真的扫描）。
    func setDemo(_ list: [Workspace], offline: Set<UUID>) {
        workspaces = list
        availability = [:]
        for workspace in list {
            for source in workspace.sources {
                availability[source.id] = offline.contains(source.id)
                    ? .offline(volumeName: source.volumeName ?? source.name)
                    : .online(path: source.path)
            }
        }
        for workspace in list {
            for source in workspace.sources where !offline.contains(source.id) { scan(source) }
        }
    }

    // MARK: - 快捷操作

    /// 打包整个工作区（只打在线来源里本机有的文件）。放在「下载」里，不覆盖同名；完成后在访达里选中。
    func zip(_ id: UUID, report: @escaping (String, Bool) -> Void) {
        guard let workspace = self.workspace(id), zipping == nil else { return }
        let online = onlineSources(workspace)
        guard !online.isEmpty else { return }
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let target = WorkspaceLogic.uniqueURL(for: WorkspaceLogic.zipName(for: workspace.name), in: folder)
        let sources = online.map { (name: $0.source.name, root: URL(fileURLWithPath: $0.path, isDirectory: true)) }
        let flag = WorkspaceCancelFlag()
        zipFlag = flag
        zipping = id
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                WorkspaceZip.make(sources: sources, target: target, isCancelled: { flag.isCancelled })
            }.value
            let store = WorkspaceStore.shared
            store.zipping = nil
            store.zipFlag = nil
            if outcome.cancelled {
                report(String(localized: "已取消打包"), false)
            } else if let url = outcome.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                var text = String(localized: "已打包 \(outcome.files) 个文件到「下载」：\(url.lastPathComponent)")
                if outcome.skippedCloud > 0 {
                    text += String(localized: "（跳过 \(outcome.skippedCloud) 个只在 iCloud 云端的文件）")
                }
                report(text, false)
            } else if outcome.failed {
                report(String(localized: "没能打包这个工作区。"), true)
            } else {
                report(String(localized: "没有可以打包的文件（只在 iCloud 云端的文件不会下载）。"), true)
            }
        }
    }

    func cancelZip() { zipFlag?.cancel() }
}

/// 页面上的一个文件格子：文件和它属于哪个来源。
struct WorkspaceFileRow: Identifiable {
    let entry: WorkspaceFileEntry
    let source: WorkspaceSource
    var id: String { entry.path }
}

/// 后台任务的取消标记（扫描、打包）：主线程设置，后台线程读。
final class WorkspaceCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
