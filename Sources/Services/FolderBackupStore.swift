import AppKit
import Combine
import UserNotifications

/// 一组配对此刻的情况（不存盘，每次检查得出）。
struct BackupPairStatus: Equatable {
    /// 硬盘接着时：硬盘文件夹现在的路径、硬盘挂载点、硬盘名字。
    var driveRoot: String?
    var volumeMount: String?
    var volumeName: String?
    /// Mac 上的文件夹找不到了（被删了、在没接上的盘上）。
    var macMissing = false
    var scanning = false
    /// 上次检查得出的结果（硬盘没接上、开关关着时为 nil）。
    var plan: BackupPlan?
    /// Mac 文件夹里只在 iCloud 云端、本机没下载的文件个数（跳过）。
    var cloudOnly = 0
    /// 硬盘剩余空间。
    var freeBytes: Int64 = 0
    var checkedAt: Date?

    var isConnected: Bool { driveRoot != nil }
}

/// 正在备份的那一组。
struct BackupRunState: Equatable {
    let pairID: UUID
    let driveName: String
    var progress: BackupProgress
    let startedAt: Date
    var cancelling = false
}

/// 拾掇 Pro「备份到硬盘」：配对、插拔硬盘时检查、提示、备份。只 Mac → 硬盘（规则见 FolderBackupLogic.swift）。
/// 主窗口关着也在后台工作（AppLifecycle 启动时 start）。
@MainActor
final class FolderBackupStore: ObservableObject {
    static let shared = FolderBackupStore()

    nonisolated static let defaultsKey = "folderBackup.pairs"
    nonisolated static let idPrefix = "io.github.hanson-zz.shiduo.folderBackup."
    nonisolated static let category = "SHIDUO_FOLDER_BACKUP"
    nonisolated static let actionPreview = "BACKUP_PREVIEW"
    nonisolated static let actionBackup = "BACKUP_NOW"
    nonisolated static let actionLater = "BACKUP_LATER"

    @Published private(set) var pairs: [BackupPair] = []
    @Published private(set) var statuses: [UUID: BackupPairStatus] = [:]
    @Published private(set) var running: BackupRunState?
    /// 主窗口「备份到硬盘」页要弹出预览的那一组。
    @Published var previewPairID: UUID?
    /// 页面顶部的一句结果（「已备份 12 个文件到 小金刚」）。
    @Published var notice: String?
    /// 通知被关掉时提醒一句。
    @Published private(set) var notificationsDenied = false

    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var cancelFlag: BackupCancelFlag?
    private var scanTokens: [UUID: UUID] = [:]

    private init() {}

    private var isPro: Bool { LicenseManager.shared.isPro }

    // MARK: - 启动

    /// applicationDidFinishLaunching 里调用：读配对，开始盯着硬盘插拔。
    func start() {
        guard !started else { return }
        started = true
        pairs = Demo.isOn ? [] : BackupPairsCodec.decode(UserDefaults.standard.data(forKey: Self.defaultsKey))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { FolderBackupStore.shared.volumeMounted(url) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { FolderBackupStore.shared.volumeUnmounted(url) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FolderBackupStore.shared.refreshAll() }
        })
        refreshAll()
    }

    /// 授权变了（试用结束 / 解锁）：重新检查（不是 Pro 时不扫描、不提示）。
    func licenseChanged() {
        guard started else { return }
        refreshAll()
    }

    /// 注册通知上的按钮。要在 applicationDidFinishLaunching 里就调用，冷启动时点的按钮才不会丢。
    nonisolated static func registerCategories() {
        let center = UNUserNotificationCenter.current()
        let preview = UNNotificationAction(identifier: actionPreview, title: String(localized: "预览"), options: [.foreground])
        let backup = UNNotificationAction(identifier: actionBackup, title: String(localized: "备份"), options: [])
        let later = UNNotificationAction(identifier: actionLater, title: String(localized: "以后"), options: [])
        let category = UNNotificationCategory(identifier: Self.category, actions: [preview, backup, later],
                                              intentIdentifiers: [], options: [])
        center.getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != Self.category }
            all.insert(category)
            center.setNotificationCategories(all)
        }
    }

    // MARK: - 配对

    func pair(_ id: UUID) -> BackupPair? { pairs.first { $0.id == id } }

    func status(_ id: UUID) -> BackupPairStatus { statuses[id] ?? BackupPairStatus() }

    /// 所有配对加起来待备份的个数（侧边栏数字）。
    var totalPending: Int {
        pairs.filter(\.enabled).reduce(0) { $0 + (statuses[$1.id]?.plan?.pendingCount ?? 0) }
    }

    /// 新建配对。出错返回原因。新配对的开关是关的。
    @discardableResult
    func addPair(mac: URL, drive: URL) -> String? {
        let macPath = FolderBackupLogic.standardized(mac.path)
        let drivePath = FolderBackupLogic.standardized(drive.path)
        let volume = Self.volumeInfo(containing: URL(fileURLWithPath: drivePath, isDirectory: true))
        if let problem = FolderBackupLogic.validate(macPath: macPath, drivePath: drivePath, driveVolume: volume, existing: pairs) {
            return problem.message
        }
        guard let volume, let rel = FolderBackupLogic.relativePath(of: drivePath, inVolume: volume.mountPath) else {
            return BackupPairProblem.driveNotExternal.message
        }
        let pair = BackupPair(macPath: macPath, macBookmark: try? URL(fileURLWithPath: macPath).bookmarkData(),
                              volumeUUID: volume.uuid, volumeName: volume.name, volumeCapacity: volume.capacity,
                              driveRelativePath: rel, driveBookmark: try? URL(fileURLWithPath: drivePath).bookmarkData())
        pairs.append(pair)
        save()
        refresh(pair.id)
        return nil
    }

    func remove(_ id: UUID) {
        if running?.pairID == id { cancel() }
        pairs.removeAll { $0.id == id }
        statuses[id] = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.idPrefix + id.uuidString])
        save()
    }

    /// 打开 / 关掉一组。打开要 Pro。
    func setEnabled(_ id: UUID, _ on: Bool) {
        if on, !requirePro() { return }
        update(id) { $0.enabled = on }
        if on {
            refresh(id)
        } else {
            if running?.pairID == id { cancel() }
            var status = self.status(id)
            status.plan = nil
            status.scanning = false
            statuses[id] = status
        }
    }

    func setAutoBackup(_ id: UUID, _ on: Bool) {
        if on, !requirePro() { return }
        update(id) { $0.autoBackupOnMount = on }
    }

    func setMirror(_ id: UUID, _ on: Bool) {
        if on, !requirePro() { return }
        update(id) { $0.mirrorDeletes = on }
    }

    private func update(_ id: UUID, _ change: (inout BackupPair) -> Void) {
        guard let index = pairs.firstIndex(where: { $0.id == id }) else { return }
        change(&pairs[index])
        save()
    }

    private func save() {
        guard !Demo.isOn else { return }
        UserDefaults.standard.set(BackupPairsCodec.encode(pairs), forKey: Self.defaultsKey)
    }

    private func requirePro() -> Bool {
        if isPro { return true }
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.show { LicenseManager.shared.showPaywall = true }
        return false
    }

    // MARK: - 硬盘

    private static let volumeKeys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey,
    ]

    private static func info(forVolume url: URL) -> BackupVolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(volumeKeys)) else { return nil }
        let rootFS = v.volumeIsRootFileSystem == true
        let external = !rootFS && !url.path.hasPrefix("/System/")
            && (v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false)
        return BackupVolumeInfo(mountPath: url.standardizedFileURL.path, uuid: v.volumeUUIDString,
                                name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
                                capacity: Int64(v.volumeTotalCapacity ?? 0), isExternal: external)
    }

    /// 现在挂着的卷。
    static func mountedVolumes() -> [BackupVolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: volumeKeys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(forVolume:))
    }

    /// 某个路径所在的卷。
    static func volumeInfo(containing url: URL) -> BackupVolumeInfo? {
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        return info(forVolume: volume)
    }

    /// 硬盘还挂在原来的位置、还是同一块盘吗。
    nonisolated static func isStillMounted(_ mountPath: String, uuid: String?) -> Bool {
        let url = URL(fileURLWithPath: mountPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: mountPath),
              let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey]),
              let volume = values.volume,
              volume.standardizedFileURL.path == url.standardizedFileURL.path else { return false }
        if let uuid { return values.volumeUUIDString?.caseInsensitiveCompare(uuid) == .orderedSame }
        return true
    }

    private func volumeMounted(_ url: URL?) {
        guard let url, let volume = Self.info(forVolume: url) else {
            refreshAll()
            return
        }
        for pair in pairs where FolderBackupLogic.matches(pair, volume: volume) {
            refresh(pair.id, afterMount: true)
        }
    }

    private func volumeUnmounted(_ url: URL?) {
        let path = url?.standardizedFileURL.path
        for (id, status) in statuses where status.volumeMount != nil && (path == nil || status.volumeMount == path) {
            var cleared = status
            cleared.driveRoot = nil
            cleared.volumeMount = nil
            cleared.plan = nil
            cleared.scanning = false
            statuses[id] = cleared
            // 正在往这块盘上拷：停下来（执行器也会自己发现硬盘没了）。
            if running?.pairID == id { cancelFlag?.cancel() }
        }
        if path == nil { refreshAll() }
    }

    // MARK: - 检查

    func refreshAll() {
        for pair in pairs { refresh(pair.id) }
    }

    /// 看一下两边：Mac 文件夹在不在（跟着书签走）、硬盘接没接；开关打开并且是 Pro 时在后台比较两边。
    func refresh(_ id: UUID, afterMount: Bool = false) {
        guard var pair = self.pair(id) else { return }
        // Mac 文件夹改名 / 挪地方：跟着书签走。
        if let data = pair.macBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let path = FolderBackupLogic.standardized(url.path)
                if path != pair.macPath, FileManager.default.fileExists(atPath: path), !path.contains("/.Trash/") {
                    update(id) {
                        $0.macPath = path
                        if stale { $0.macBookmark = try? url.bookmarkData() }
                    }
                    pair = self.pair(id) ?? pair
                }
            }
        }
        var status = BackupPairStatus()
        var isDir: ObjCBool = false
        status.macMissing = !(FileManager.default.fileExists(atPath: pair.macPath, isDirectory: &isDir) && isDir.boolValue)
        if let volume = Self.mountedVolumes().first(where: { FolderBackupLogic.matches(pair, volume: $0) }) {
            status.volumeMount = volume.mountPath
            status.volumeName = volume.name
            status.driveRoot = followDriveBookmark(pair, volume: volume) ?? FolderBackupLogic.driveRoot(for: pair, volumeMount: volume.mountPath)
            status.freeBytes = MoveOutEngine.availableBytes(at: URL(fileURLWithPath: volume.mountPath, isDirectory: true))
        }
        status.plan = nil
        guard pair.enabled, isPro, let driveRoot = status.driveRoot, !status.macMissing,
              BackupRoots(mac: pair.macPath, drive: driveRoot) != nil else {
            scanTokens[id] = nil
            statuses[id] = status
            return
        }
        status.scanning = true
        statuses[id] = status
        let token = UUID()
        scanTokens[id] = token
        let macPath = pair.macPath
        Task { @MainActor in
            let (plan, cloudOnly) = await Task.detached(priority: .utility) { () -> (BackupPlan, Int) in
                let macSide = BackupScanner.scan(macPath)
                let driveSide = BackupScanner.scan(driveRoot, skipCloudOnly: false)
                let plan = FolderBackupLogic.plan(mac: macSide.entries, drive: driveSide.entries,
                                                  leftoverTemps: driveSide.leftoverTemps)
                return (plan, macSide.cloudOnly)
            }.value
            let store = FolderBackupStore.shared
            guard store.scanTokens[id] == token else { return }
            store.scanTokens[id] = nil
            var done = store.status(id)
            done.scanning = false
            done.plan = plan
            done.cloudOnly = cloudOnly
            done.checkedAt = Date()
            store.statuses[id] = done
            store.update(id) { $0.lastPending = plan.pendingCount }
            if afterMount { store.afterMountCheck(id) }
        }
    }

    /// 硬盘接着时，硬盘文件夹在盘里改了名 / 挪了地方：跟过去（只认同一块盘里的位置）。
    private func followDriveBookmark(_ pair: BackupPair, volume: BackupVolumeInfo) -> String? {
        guard let data = pair.driveBookmark else { return nil }
        let expected = FolderBackupLogic.driveRoot(for: pair, volumeMount: volume.mountPath)
        if let expected, FileManager.default.fileExists(atPath: expected) { return expected }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path), !url.path.contains("/.Trashes/"),
              let rel = FolderBackupLogic.relativePath(of: url.path, inVolume: volume.mountPath) else { return nil }
        update(pair.id) {
            $0.driveRelativePath = rel
            if stale { $0.driveBookmark = try? url.bookmarkData() }
        }
        return FolderBackupLogic.standardized(url.path)
    }

    /// 插上硬盘、检查完：按设置弹提示或自动备份。
    private func afterMountCheck(_ id: UUID) {
        guard let pair = self.pair(id), let plan = status(id).plan else { return }
        let driveName = status(id).volumeName ?? pair.volumeName
        switch FolderBackupLogic.mountAction(pair: pair, isPro: isPro, pendingCount: plan.pendingCount) {
        case .nothing:
            break
        case .prompt(let count):
            Task { await postPrompt(pair, count: count, driveName: driveName) }
        case .autoBackup:
            // 自动备份从不删除硬盘上的东西。
            backup(id, includeDeletes: false, announce: true)
        }
    }

    // MARK: - 提示

    private func postPrompt(_ pair: BackupPair, count: Int, driveName: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        notificationsDenied = !granted
        guard granted else {
            promptInApp(pair, count: count, driveName: driveName)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "备份到硬盘：\(pair.macName)")
        content.body = FolderBackupLogic.promptText(count: count, driveName: driveName)
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["pairID": pair.id.uuidString]
        let request = UNNotificationRequest(identifier: Self.idPrefix + pair.id.uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// 通知被关掉了：拾掇在前台时弹一个对话框（在后台就不打扰，页面和侧边栏上有数字）。
    private func promptInApp(_ pair: BackupPair, count: Int, driveName: String) {
        guard NSApp.isActive else { return }
        let alert = NSAlert()
        alert.messageText = FolderBackupLogic.promptText(count: count, driveName: driveName)
        alert.informativeText = String(localized: "来自「\(pair.macName)」，只从 Mac 拷到硬盘，不会删除硬盘上的文件。")
        alert.addButton(withTitle: String(localized: "备份"))
        alert.addButton(withTitle: String(localized: "预览"))
        alert.addButton(withTitle: String(localized: "以后"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: backup(pair.id, includeDeletes: false, announce: false)
        case .alertSecondButtonReturn: openPreview(pair.id)
        default: break
        }
    }

    /// 点了通知（或通知上的按钮）。
    func handleNotification(action: String, pairID: UUID) {
        guard pair(pairID) != nil else { return }
        switch action {
        case Self.actionBackup:
            // 通知上的「备份」从不删除硬盘上的东西（删除只能在预览里确认）。
            backup(pairID, includeDeletes: false, announce: true)
        case Self.actionLater, UNNotificationDismissActionIdentifier:
            break
        default:
            openPreview(pairID)
        }
    }

    /// 打开主窗口的「备份到硬盘」页并弹出预览。
    func openPreview(_ id: UUID) {
        MainWindow.show {
            LibraryStore.shared?.selection = .folderBackup
            FolderBackupStore.shared.previewPairID = id
        }
    }

    // MARK: - 备份

    var isRunning: Bool { running != nil }

    func cancel() {
        guard running != nil else { return }
        running?.cancelling = true
        cancelFlag?.cancel()
    }

    /// 能不能现在备份（不能时返回原因）。
    func blocker(_ id: UUID) -> String? {
        guard let pair = self.pair(id) else { return String(localized: "找不到这组配对") }
        if !isPro { return String(localized: "备份到硬盘是 Pro 功能") }
        if !pair.enabled { return String(localized: "先打开这一组的开关") }
        let status = self.status(id)
        if status.macMissing { return String(localized: "Mac 上的文件夹找不到了") }
        if !status.isConnected { return String(localized: "硬盘没接上") }
        if status.scanning { return String(localized: "正在比较…") }
        if running != nil { return String(localized: "正在备份另一组，请稍等") }
        if let plan = status.plan,
           !FolderBackupLogic.hasEnoughSpace(required: FolderBackupLogic.requiredBytes(plan), available: status.freeBytes) {
            return String(localized: "硬盘空间不够")
        }
        return nil
    }

    /// 备份一组。includeDeletes 只有在预览里打开了镜像、又在红色确认框里点了确认时才是 true。
    /// announce：做完后发通知（从通知 / 自动备份发起的，用户不一定在看拾掇）。
    func backup(_ id: UUID, includeDeletes: Bool, announce: Bool) {
        guard let pair = self.pair(id) else { return }
        if !isPro {
            _ = requirePro()
            return
        }
        guard blocker(id) == nil, let plan = status(id).plan, let driveRoot = status(id).driveRoot,
              let mount = status(id).volumeMount, let roots = BackupRoots(mac: pair.macPath, drive: driveRoot) else {
            if let reason = blocker(id) { notice = reason }
            return
        }
        let allowDeletes = FolderBackupLogic.deletionAllowed(pair: pair, userConfirmed: includeDeletes)
        let steps = plan.steps(includeDeletes: allowDeletes)
        guard !steps.isEmpty else {
            notice = String(localized: "「\(pair.macName)」已经是最新的了")
            return
        }
        let flag = BackupCancelFlag()
        cancelFlag = flag
        let driveName = status(id).volumeName ?? pair.volumeName
        running = BackupRunState(pairID: id, driveName: driveName,
                                 progress: BackupProgress(fileCount: plan.pendingCount, bytesTotal: plan.bytesToCopy),
                                 startedAt: Date())
        notice = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.idPrefix + id.uuidString])
        let uuid = pair.volumeUUID
        let io = Self.appIO(mountPath: mount, uuid: uuid, flag: flag)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> BackupRunResult in
                var throttle = MoveProgressLogic.Throttle(interval: 0.1)
                return BackupExecutor.run(steps, roots: roots, allowDeletes: allowDeletes, io: io, cancel: flag) { progress in
                    let finished = progress.fileCount > 0 && progress.filesDone >= progress.fileCount
                    guard throttle.shouldEmit(now: Date(), force: progress.filesDone == 0 || finished) else { return }
                    Task { @MainActor in
                        let store = FolderBackupStore.shared
                        guard store.cancelFlag === flag, var state = store.running else { return }
                        state.progress = progress
                        store.running = state
                    }
                }
            }.value
            FolderBackupStore.shared.finish(id, result: result, driveName: driveName, announce: announce, flag: flag)
        }
    }

    private func finish(_ id: UUID, result: BackupRunResult, driveName: String, announce: Bool, flag: BackupCancelFlag) {
        guard cancelFlag === flag else { return }
        cancelFlag = nil
        running = nil
        let name = self.pair(id)?.macName ?? ""
        let message: String
        if result.refused {
            message = String(localized: "没有备份：Mac 上的「\(name)」找不到了，或者硬盘上的文件夹建不起来")
        } else if result.driveDisconnected {
            message = String(localized: "「\(driveName)」被拔掉了：已拷好 \(result.copied) 个，剩下的下次插上再备份（硬盘上的旧版本没有被弄坏）")
        } else if result.cancelled {
            message = String(localized: "已取消：拷好了 \(result.copied) 个文件，剩下的下次再备份")
        } else {
            var parts = [String(localized: "已备份 \(result.copied) 个文件到「\(driveName)」")]
            if result.trashed > 0 { parts.append(String(localized: "\(result.trashed) 项移到了硬盘的废纸篓")) }
            if !result.failed.isEmpty { parts.append(String(localized: "\(result.failed.count) 个没拷成（可能被占用或没有权限）")) }
            if !result.trashFailed.isEmpty { parts.append(String(localized: "\(result.trashFailed.count) 项没能移到废纸篓，留在了硬盘上")) }
            message = parts.joined(separator: String(localized: "，"))
        }
        notice = message
        if !result.refused, !result.driveDisconnected, !result.cancelled {
            update(id) { $0.lastBackup = Date() }
        }
        if announce { Task { await postResult(message) } }
        refresh(id)
    }

    private func postResult(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "备份到硬盘")
        content.body = message
        let request = UNNotificationRequest(identifier: Self.idPrefix + "result." + UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// App 里真正的文件操作：copyfile（带上扩展属性、权限、日期，有字节进度、能取消）；
    /// 废纸篓只用硬盘自己的（找不到硬盘上的废纸篓就不删，绝不会把东西挪到 Mac 上）。
    nonisolated private static func appIO(mountPath: String, uuid: String?, flag: BackupCancelFlag) -> BackupIO {
        let mount = FolderBackupLogic.standardized(mountPath)
        let moveOutFlag = MoveOutCancelFlag()
        return BackupIO(
            copyItem: { from, to, onBytes in
                if flag.isCancelled { moveOutFlag.cancel() }
                guard MoveOutEngine.copyVerified(from, to: to, cancel: moveOutFlag, onBytes: { bytes in
                    if flag.isCancelled { moveOutFlag.cancel() }
                    onBytes(bytes)
                }) != nil else {
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            trashItem: { url in
                let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: true)
                guard FolderBackupLogic.isInside(trash.path, mount) else { throw CocoaError(.fileWriteNoPermission) }
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let landed = resulting as URL?, !FolderBackupLogic.isInside(landed.path, mount) {
                    // 万一系统把它放进了 Mac 的废纸篓：挪回硬盘原处，当作没删成。
                    try? FileManager.default.moveItem(at: landed, to: url)
                    throw CocoaError(.fileWriteNoPermission)
                }
            },
            isDriveAvailable: { FolderBackupStore.isStillMounted(mount, uuid: uuid) }
        )
    }
}
