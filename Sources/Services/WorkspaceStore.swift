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
    /// 系统没给权限读取的来源（扫描读不到根目录）：卡片上显示「没有权限读取」，之前的缓存不覆盖。
    @Published private(set) var denied: Set<UUID> = []
    /// 正在打包的工作区。
    @Published private(set) var zipping: UUID?
    /// 页面上要进入改名状态的工作区（双击标题、菜单「重命名」）。
    @Published var renamingInline: UUID?
    /// 配置来自更新版本的拾掇：这次运行只读（不写回去），页面上提示一句。
    @Published private(set) var readOnlyNotice: String?

    private var file = WorkspacesFile()
    private var readOnly = false
    private var scanFlags: [UUID: WorkspaceCancelFlag] = [:]
    private var zipFlag: WorkspaceCancelFlag?
    private var zipJob: WorkspaceZipJob?
    private var observers: [NSObjectProtocol] = []
    /// 正在显示的工作区（页面开着几个）：计数归零才停扫描；插盘时只扫正在显示的。
    private var visible: [UUID: Int] = [:]
    /// 正在后台判定状态的来源。
    private var checking: Set<UUID> = []
    /// 分类卡片缩略图：路径 → 后台建好的条目。
    @Published private(set) var previewItems: [String: FileItem] = [:]
    private var previewLoading: Set<String> = []

    private init() {
        if !Demo.isOn {
            let defaults = UserDefaults.standard
            let stored = defaults.object(forKey: Self.defaultsKey)
            if let stored, !(stored is Data) {
                // 键里存的不是数据（被别的东西写坏了）：原样备份，这次不保存默认值。
                Self.backup(stored)
                file = WorkspaceCodec.decode(nil)
            } else {
                let loaded = WorkspaceCodec.load(stored as? Data)
                if loaded.needsBackup, let raw = stored as? Data { Self.backup(raw) }
                file = loaded.file
                readOnly = loaded.readOnly
                if loaded.readOnly {
                    readOnlyNotice = String(localized: "工作区配置来自更新版本的拾掇，这次的修改不会保存（原来的配置已备份）。")
                }
                // 只有第一次用（刚建了默认工作区）才马上存。读出来的旧数据不再无条件写回去：
                // 读不出来的不会被默认值覆盖；切换语言时两个实例也不会互相覆盖。
                if loaded.needsSave { save() }
            }
            workspaces = file.workspaces
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

    /// 统计：落在别的来源里面的来源不重复算（父子文件夹都加了的时候）。
    func totals(_ workspace: Workspace) -> WorkspaceTotals {
        let skip = nested(workspace)
        var t = WorkspaceLogic.totals(workspace.sources.filter { skip[$0.id] == nil }.map { stats($0) })
        t.sources = workspace.sources.count
        return t
    }

    /// 落在别的来源里面的来源（来源 id → 包含它的来源名字），按来源此刻的路径判断。
    func nested(_ workspace: Workspace) -> [UUID: String] {
        WorkspaceLogic.nestedSources(workspace.sources.map { (id: $0.id, path: state($0).path ?? $0.path, name: $0.name) })
    }

    /// 打包用的来源：在线的，去掉落在别的来源里面的（同一批文件不打两遍）。
    func zipSources(_ workspace: Workspace) -> [(source: WorkspaceSource, path: String)] {
        let skip = nested(workspace)
        return onlineSources(workspace).filter { skip[$0.source.id] == nil }
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
        let skip = nested(workspace)
        for source in workspace.sources where skip[source.id] == nil {
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
        if zipping == id { cancelZip() }
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

    /// 读不懂的原始配置原样存到 workspaces.backup.<时间>（同样的内容只备份一份）。
    private static func backup(_ value: Any) {
        let defaults = UserDefaults.standard
        let existing = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(WorkspaceCodec.backupPrefix) }
        if let data = value as? Data, existing.values.contains(where: { ($0 as? Data) == data }) { return }
        defaults.set(value, forKey: WorkspaceCodec.backupKey(Date()))
    }

    private func save() {
        guard !Demo.isOn, !readOnly else { return }
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
        var replaced: Set<UUID> = []
        var problems: [String] = []
        for url in urls {
            guard LibraryStore.isBrowsableFolder(url) else {
                problems.append(String(localized: "「\(url.lastPathComponent)」不是文件夹"))
                continue
            }
            let current = workspace.sources.filter { !replaced.contains($0.id) } + added
            if let problem = WorkspaceLogic.addProblem(path: url.path, existing: current) {
                switch problem {
                case .alreadyAdded(let name): problems.append(String(localized: "「\(name)」已经在这个工作区里了"))
                case .insideExisting(let name): problems.append(String(localized: "「\(url.lastPathComponent)」已经包含在「\(name)」里"))
                case .notFolder: problems.append(String(localized: "「\(url.lastPathComponent)」不是文件夹"))
                case .tooBroad: problems.append(String(localized: "「\(url.lastPathComponent)」范围太大（整个磁盘或用户文件夹），请选里面具体的文件夹"))
                case .containsExisting(let ids, let names):
                    // 父文件夹后加：问一下要不要换掉里面那几个来源（只删记录），不然同一批文件会算两遍。
                    let batch = Set(added.map(\.id))
                    let fromWorkspace = ids.filter { !batch.contains($0) }
                    if !fromWorkspace.isEmpty, !confirmReplace(parent: url.lastPathComponent, children: names) {
                        problems.append(String(localized: "「\(url.lastPathComponent)」没有添加（它包含已有的来源）"))
                        continue
                    }
                    added.removeAll { ids.contains($0.id) }
                    replaced.formUnion(fromWorkspace)
                    let volume = FolderBackupStore.volumeInfo(containing: url)
                    added.append(WorkspaceLogic.makeSource(url: url, volume: volume))
                }
                continue
            }
            let volume = FolderBackupStore.volumeInfo(containing: url)
            added.append(WorkspaceLogic.makeSource(url: url, volume: volume))
        }
        guard !added.isEmpty else { return problems.first }
        for sourceID in replaced {
            cancelScan(sourceID)
            availability[sourceID] = nil
            live[sourceID] = nil
        }
        workspace.sources.removeAll { replaced.contains($0.id) }
        workspace.sources.append(contentsOf: added)
        update(id) { $0.sources = workspace.sources }
        for source in added {
            availability[source.id] = .online(path: source.path)
            scan(source)
        }
        var message = String(localized: "已添加 \(added.count) 个文件夹（只记位置，原文件不动）")
        if !replaced.isEmpty { message += String(localized: "，替换了里面的 \(replaced.count) 个来源") }
        return Self.joined([message] + problems)
    }

    /// 几句提示连成一句（中文用「；」，英文用「; 」）。
    static func joined(_ parts: [String]) -> String {
        guard var out = parts.first else { return "" }
        for part in parts.dropFirst() { out = String(localized: "\(out)；\(part)") }
        return out
    }

    /// 父文件夹后加：确认换掉里面的来源（只删记录，文件不动）。
    private func confirmReplace(parent: String, children: [String]) -> Bool {
        let alert = NSAlert()
        let list = ListFormatter.localizedString(byJoining: children.map { "「\($0)」" })
        alert.messageText = String(localized: "「\(parent)」包含已有的来源 \(list)，换成「\(parent)」吗？")
        alert.informativeText = String(localized: "只从工作区移除里面那几个来源的记录，文件夹和文件都不会动。不换的话，同一批文件会被算两遍。")
        alert.addButton(withTitle: String(localized: "替换"))
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 从工作区移除一个来源：只删引用，文件夹本身不动。
    func removeSource(_ sourceID: UUID, from id: UUID) {
        cancelScan(sourceID)
        update(id) { $0.sources.removeAll { $0.id == sourceID } }
        availability[sourceID] = nil
        live[sourceID] = nil
        denied.remove(sourceID)
    }

    /// 打开 系统设置 › 隐私与安全性 › 文件与文件夹（没有权限读取的来源用）。
    static func openPrivacySettings() {
        let links = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
                     "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"]
        for link in links {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - 状态 / 扫描

    /// 一个来源判定完的结果（后台算好，回主线程再写）。
    struct SourceCheck {
        let id: UUID
        let state: WorkspaceSourceAvailability
        /// 书签过期了：新书签。
        var bookmark: Data?
        /// 文件夹改名 / 挪了地方：新路径（和新的相对路径）。
        var path: String?
        var relativePath: String?
    }

    /// 判定来源状态（书签解析、stat）的后台队列：网络盘没响应时卡住的只是这一个来源，界面不转圈。
    nonisolated private static let ioQueue = DispatchQueue(label: "io.github.hanson-zz.shiduo.workspace.io",
                                                           qos: .userInitiated, attributes: .concurrent)

    /// 扫描专用队列：不占 Swift 并发的协作线程池（扫描是长时间的同步 IO），同时最多扫 2 个来源。
    nonisolated private static let scanQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.hanson-zz.shiduo.workspace.scan"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    /// 重新判定所有来源的状态：书签跟着改名 / 移动走，外接硬盘看接没接上。
    /// 在后台做（读卷列表、解析书签、stat 都可能卡在没响应的网络盘上），每个来源判定完就发布；全部完成后调用 completion。
    func refreshAvailability(_ completion: (() -> Void)? = nil) {
        let isDemo = Demo.isOn
        // 上一次还没判定完的来源（比如卡在网络盘上）不重复排队。
        let sources = workspaces.flatMap(\.sources).filter { !checking.contains($0.id) }
        checking.formUnion(sources.map(\.id))
        let group = DispatchGroup()
        group.enter()
        Self.ioQueue.async {
            let mounted = isDemo ? [] : FolderBackupStore.mountedVolumes()
            for source in sources {
                group.enter()
                Self.ioQueue.async {
                    let check = Self.check(source, mounted: mounted, resolveBookmark: !isDemo)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { WorkspaceStore.shared.apply(check) }
                        group.leave()
                    }
                }
            }
            group.leave()
        }
        group.notify(queue: .main) { completion?() }
    }

    /// 判定一个来源（后台线程）：书签过期只在来源确实在线、而且不在废纸篓里时才重新生成（别把书签改成指向废纸篓）。
    nonisolated static func check(_ source: WorkspaceSource, mounted: [BackupVolumeInfo], resolveBookmark: Bool) -> SourceCheck {
        var resolved: String?
        var stale = false
        if resolveBookmark, let data = source.bookmark,
           let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            resolved = url.path
        }
        let state = WorkspaceLogic.availability(of: source, resolvedPath: resolved, mounted: mounted, isFolder: isFolder)
        var check = SourceCheck(id: source.id, state: state)
        guard let path = state.path else { return check }
        if stale, !WorkspaceLogic.isInTrash(path) {
            check.bookmark = try? URL(fileURLWithPath: path, isDirectory: true).bookmarkData()
        }
        if path != source.path {
            // 文件夹改名 / 挪了地方：跟过去（显示的名字也跟着变）。
            check.path = path
            if source.isOnExternalVolume, let volume = mounted.first(where: { WorkspaceLogic.matches(source, volume: $0) }) {
                check.relativePath = FolderBackupLogic.relativePath(of: path, inVolume: volume.mountPath)
            }
        }
        return check
    }

    private func apply(_ check: SourceCheck) {
        checking.remove(check.id)
        guard let wi = workspaces.firstIndex(where: { $0.sources.contains { $0.id == check.id } }),
              let si = workspaces[wi].sources.firstIndex(where: { $0.id == check.id }) else { return }
        var changed = false
        if let bookmark = check.bookmark {
            workspaces[wi].sources[si].bookmark = bookmark
            changed = true
        }
        if let path = check.path {
            workspaces[wi].sources[si].path = path
            if let rel = check.relativePath { workspaces[wi].sources[si].relativePath = rel }
            changed = true
        }
        if availability[check.id] != check.state { availability[check.id] = check.state }
        if changed { save() }
    }

    /// 写文件之前（新建文件夹）再同步确认一次来源还在：在线、而且外接 / 可断开的卷还挂在原处、还是同一块盘。
    /// 返回现在的路径；不在了返回 nil。
    func verifiedPath(_ sourceID: UUID) -> String? {
        guard let source = workspaces.flatMap(\.sources).first(where: { $0.id == sourceID }) else { return nil }
        let mounted = Demo.isOn ? [] : FolderBackupStore.mountedVolumes()
        let check = Self.check(source, mounted: mounted, resolveBookmark: !Demo.isOn)
        apply(check)
        guard let path = check.state.path else { return nil }
        if !Demo.isOn, source.isOnExternalVolume {
            guard let volume = mounted.first(where: { WorkspaceLogic.matches(source, volume: $0) }),
                  FolderBackupStore.isStillMounted(volume.mountPath, uuid: volume.uuid),
                  FolderBackupLogic.isInside(path, volume.mountPath) else { return nil }
        }
        return path
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 插拔硬盘：重新判定状态。刚接上的硬盘上的来源：正在显示的工作区马上重新扫描；
    /// 没在显示的只标成「待更新」（丢掉这次的结果），打开页面时再扫，不一次扫所有工作区。
    private func volumesChanged() {
        let before = availability
        refreshAvailability { [weak self] in
            guard let self else { return }
            for workspace in self.workspaces {
                let shown = self.isVisible(workspace.id) && (WorkspaceAccess.unlocked || Demo.isOn)
                for source in workspace.sources {
                    let now = self.state(source)
                    if now.isOnline, before[source.id]?.isOnline != true {
                        if shown { self.scan(source) } else { self.live[source.id] = nil }
                    }
                    if !now.isOnline { self.cancelScan(source.id) }
                }
            }
        }
    }

    /// 工作区页面出现：记下它在显示（双栏 / 多标签可能同时开着同一个工作区），判定状态并扫描。
    func pageAppeared(_ id: UUID) {
        visible[id, default: 0] += 1
        refresh(id)
    }

    /// 工作区页面消失：所有显示它的页面都关了才停下扫描（不会把另一栏还在看的扫描停掉）。
    func pageDisappeared(_ id: UUID) {
        let count = (visible[id] ?? 1) - 1
        visible[id] = count > 0 ? count : nil
        if count <= 0 { cancelScans(id) }
    }

    private func isVisible(_ id: UUID) -> Bool { (visible[id] ?? 0) > 0 }

    /// 打开工作区页面时：判定状态，在线但这次还没扫过的来源在后台扫一遍（force：全部重扫）。
    /// 试用到期（页面显示「拾掇 Pro」介绍）时只判定状态，不扫描。
    func refresh(_ id: UUID, force: Bool = false) {
        guard !Demo.isOn || force else { return }
        refreshAvailability { [weak self] in
            guard let self, let workspace = self.workspace(id) else { return }
            self.preparePreviews(workspace)
            guard WorkspaceAccess.unlocked || Demo.isOn else { return }
            for source in workspace.sources where self.state(source).isOnline {
                if force || (self.live[source.id] == nil && !self.scanning.contains(source.id)) { self.scan(source) }
            }
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
        Self.scanQueue.addOperation {
            // 排队期间被取消了：直接跳过。
            let result = flag.isCancelled ? nil : WorkspaceScanner.scan(root: root, isCancelled: { flag.isCancelled })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WorkspaceStore.shared.finishScan(sourceID, flag: flag, result: result) }
            }
        }
    }

    private func finishScan(_ sourceID: UUID, flag: WorkspaceCancelFlag, result: WorkspaceScanner.Result?) {
        guard scanFlags[sourceID] === flag else { return }
        scanFlags[sourceID] = nil
        scanning.remove(sourceID)
        guard let result, !flag.isCancelled else { return }
        if result.permissionDenied {
            // 读不了不等于「0 个文件」：不写缓存，卡片上提示去给权限。
            denied.insert(sourceID)
            return
        }
        denied.remove(sourceID)
        live[sourceID] = result
        storeStats(result.stats, for: sourceID)
        if let workspace = workspaces.first(where: { $0.sources.contains { $0.id == sourceID } }) { preparePreviews(workspace) }
    }

    // MARK: - 分类卡片的缩略图

    /// 分类卡片上斜叠的几张的候选：只用本机有的文件（不为了缩略图去下载云端文件）。
    func previewCandidates(_ kind: WorkspaceFileKind, workspace: Workspace) -> [String] {
        let live = files(workspace, kind: kind, limit: 6).map(\.entry)
        let pool = live.isEmpty ? recentFiles(workspace, limit: 60).map(\.entry).filter { $0.kind == kind } : live
        return pool.filter { !$0.cloudOnly }.prefix(3).map(\.path)
    }

    /// 已经在后台建好的缩略图条目（body 里只读缓存，不在主线程上读 Spotlight / 扩展属性）。
    func previews(_ kind: WorkspaceFileKind, workspace: Workspace) -> [FileItem] {
        previewCandidates(kind, workspace: workspace).compactMap { previewItems[$0] }
    }

    /// 在后台把缩略图要用的 FileItem 建好，建好后发布。
    private func preparePreviews(_ workspace: Workspace) {
        let paths = WorkspaceFileKind.allCases.flatMap { previewCandidates($0, workspace: workspace) }
        let todo = paths.filter { previewItems[$0] == nil && !previewLoading.contains($0) }
        guard !todo.isEmpty else { return }
        if previewItems.count > 400 { previewItems.removeAll() }
        previewLoading.formUnion(todo)
        Self.ioQueue.async {
            let items = todo.compactMap { path in FileItem(url: URL(fileURLWithPath: path)).map { (path, $0) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = WorkspaceStore.shared
                    store.previewLoading.subtract(todo)
                    for (path, item) in items { store.previewItems[path] = item }
                }
            }
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

    /// 打包默认放哪：「下载」；演示模式放演示临时目录（演示不碰用户真实的文件夹）。
    static var defaultZipFolder: URL {
        if Demo.isOn { return Demo.folder }
        let fm = FileManager.default
        return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
    }

    /// 打包整个工作区（只打在线来源里本机有的文件，落在别的来源里面的不重复打）。放在 folder 里，不覆盖同名；完成后在访达里选中。
    func zip(_ id: UUID, to folder: URL, report: @escaping (String, Bool) -> Void) {
        guard let workspace = self.workspace(id), zipping == nil else { return }
        let online = zipSources(workspace)
        guard !online.isEmpty else { return }
        let target = WorkspaceLogic.uniqueURL(for: WorkspaceLogic.zipName(for: workspace.name), in: folder)
        let sources = online.map { (name: $0.source.name, root: URL(fileURLWithPath: $0.path, isDirectory: true)) }
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let flag = WorkspaceCancelFlag()
        let job = WorkspaceZipJob()
        zipFlag = flag
        zipJob = job
        zipping = id
        // 专用线程上跑：等压缩子进程是阻塞的，不能占 Swift 并发的协作线程池。
        DispatchQueue.global(qos: .userInitiated).async {
            Self.cleanUpZipLeftovers(in: folder)
            let outcome = WorkspaceZip.make(sources: sources, target: target, isCancelled: { flag.isCancelled }, job: job)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WorkspaceStore.shared.finishZip(outcome, folderName: folderName, report: report)
                }
            }
        }
    }

    private func finishZip(_ outcome: WorkspaceZip.Outcome, folderName: String, report: (String, Bool) -> Void) {
        zipping = nil
        zipFlag = nil
        zipJob = nil
        var notes: [String] = []
        if outcome.skippedCloud > 0 { notes.append(String(localized: "跳过 \(outcome.skippedCloud) 个只在云端的文件")) }
        if !outcome.unreadable.isEmpty {
            let examples = outcome.unreadable.prefix(3).map { ($0 as NSString).lastPathComponent }
            notes.append(String(localized: "\(outcome.unreadable.count) 个文件读不了，已跳过（例如 \(ListFormatter.localizedString(byJoining: examples))）"))
        }
        if !outcome.unavailableSources.isEmpty {
            let names = ListFormatter.localizedString(byJoining: outcome.unavailableSources.map { "「\($0)」" })
            notes.append(String(localized: "\(names) 没有连接或没有权限读取，没打包"))
        }
        if outcome.cancelled {
            report(String(localized: "已取消打包"), false)
        } else if outcome.outOfSpace {
            report(String(localized: "磁盘剩余空间快不够了，已停止打包，没有留下不完整的 ZIP。"), true)
        } else if let url = outcome.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let text = String(localized: "已打包 \(outcome.files) 个文件到「\(folderName)」：\(url.lastPathComponent)")
            // 有文件读不了、有来源没打包：用提示框，别让用户错过。
            let important = !outcome.unreadable.isEmpty || !outcome.unavailableSources.isEmpty
            report(Self.joined([text] + notes), important)
        } else if outcome.failed {
            report(String(localized: "没能打包这个工作区。"), true)
        } else if !outcome.unavailableSources.isEmpty {
            report(Self.joined(notes), true)
        } else {
            report(String(localized: "没有可以打包的文件（只在云端的文件不会下载）。"), true)
        }
    }

    /// 清掉以前留下的打包临时文件（只认拾掇自己起的名字、超过一天的）。只在用户打包时看目标文件夹，
    /// 不在启动时去读「下载」（免得弹出系统权限框）。
    nonisolated private static func cleanUpZipLeftovers(in folder: URL) {
        let fm = FileManager.default
        for dir in [folder, fm.temporaryDirectory] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let url = dir.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true, let modified = values.contentModificationDate,
                      WorkspaceZip.isStaleLeftover(name: name, modified: modified) else { continue }
                try? fm.removeItem(at: url)
            }
        }
    }

    func cancelZip() {
        zipFlag?.cancel()
        zipJob?.stop()
    }
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
