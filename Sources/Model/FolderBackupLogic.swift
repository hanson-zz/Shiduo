import Foundation

// 拾掇 Pro「备份到硬盘」不碰界面的部分：单元测试直接编译这个文件。
//
// 规则（用户 2026-10-28 定）：
// - 一组配对 = Mac 上的一个文件夹 ↔ 移动硬盘上的一个文件夹；每组一个开关，默认关。
// - 只单向：Mac → 硬盘。任何情况下都不把硬盘上的东西拷回 Mac（Mac 空间不一定够）。
//   这里的做法：步骤（BackupStep）里只有相对路径；拷贝的「从哪」只能由 BackupRoots.source 从 Mac 文件夹拼出来，
//   「到哪」只能由 BackupRoots.target 从硬盘文件夹拼出来，执行器每次写之前还要核对目标在硬盘文件夹里、不在 Mac 文件夹里。
//   没有任何一种步骤会往 Mac 那边写东西。
// - 默认绝不删硬盘上的文件：只在硬盘上的只列出来。每组可以打开「镜像」，但每次删除都要用户在预览里再确认一次，
//   而且只移到硬盘的废纸篓（移不进去就留着，不直接删）。插上就自动备份、通知上的「备份」都不删。
// - 比较只看大小 + 修改时间（FAT / exFAT 的时间精度是 2 秒，差 2 秒以内算一样）。

// MARK: - 配对

/// 一组备份配对。存成带版本号的 JSON（BackupPairsFile）。
struct BackupPair: Codable, Identifiable, Equatable {
    var id: UUID
    /// Mac 上的文件夹（绝对路径）。
    var macPath: String
    /// Mac 文件夹的书签：文件夹改名 / 挪地方后跟过去（拾掇没开沙盒，普通书签就够了）。
    var macBookmark: Data?
    /// 硬盘的卷 UUID（认硬盘靠它，不靠名字）。个别格式读不到时为 nil，退回「名字 + 容量」。
    var volumeUUID: String?
    /// 硬盘名字（显示用；没有 UUID 时也用来认盘）。
    var volumeName: String
    /// 硬盘容量（没有 UUID 时和名字一起认盘）。
    var volumeCapacity: Int64
    /// 硬盘上的文件夹，相对于硬盘根目录（"" = 硬盘根目录）。硬盘每次挂载的位置可能不同（/Volumes/盘名 1）。
    var driveRelativePath: String
    /// 硬盘文件夹的书签（硬盘接着时，文件夹在硬盘里改名 / 挪地方后跟过去）。
    var driveBookmark: Data?
    /// 总开关：默认关，用户自己打开才会检查、提示、备份。
    var enabled: Bool
    /// 插上硬盘就自动备份（默认关；自动备份从不删除硬盘上的文件）。
    var autoBackupOnMount: Bool
    /// 镜像：允许把硬盘上 Mac 已经删掉的文件移到硬盘废纸篓（默认关；每次仍要在预览里确认）。
    var mirrorDeletes: Bool
    /// 上次备份完成的时间。
    var lastBackup: Date?
    /// 上次检查时待备份的个数（硬盘拔掉后还能显示）。
    var lastPending: Int?
    var created: Date

    init(id: UUID = UUID(), macPath: String, macBookmark: Data? = nil, volumeUUID: String?, volumeName: String,
         volumeCapacity: Int64, driveRelativePath: String, driveBookmark: Data? = nil, enabled: Bool = false,
         autoBackupOnMount: Bool = false, mirrorDeletes: Bool = false, lastBackup: Date? = nil,
         lastPending: Int? = nil, created: Date = Date()) {
        self.id = id
        self.macPath = macPath
        self.macBookmark = macBookmark
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.volumeCapacity = volumeCapacity
        self.driveRelativePath = driveRelativePath
        self.driveBookmark = driveBookmark
        self.enabled = enabled
        self.autoBackupOnMount = autoBackupOnMount
        self.mirrorDeletes = mirrorDeletes
        self.lastBackup = lastBackup
        self.lastPending = lastPending
        self.created = created
    }

    private enum CodingKeys: String, CodingKey {
        case id, macPath, macBookmark, volumeUUID, volumeName, volumeCapacity, driveRelativePath, driveBookmark
        case enabled, autoBackupOnMount, mirrorDeletes, lastBackup, lastPending, created
    }

    /// 宽松解码：缺的开关一律按「关」，缺的其他字段用安全的默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        macPath = try c.decode(String.self, forKey: .macPath)
        macBookmark = try? c.decode(Data.self, forKey: .macBookmark)
        volumeUUID = try? c.decode(String.self, forKey: .volumeUUID)
        volumeName = (try? c.decode(String.self, forKey: .volumeName)) ?? ""
        volumeCapacity = (try? c.decode(Int64.self, forKey: .volumeCapacity)) ?? 0
        driveRelativePath = (try? c.decode(String.self, forKey: .driveRelativePath)) ?? ""
        driveBookmark = try? c.decode(Data.self, forKey: .driveBookmark)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        autoBackupOnMount = (try? c.decode(Bool.self, forKey: .autoBackupOnMount)) ?? false
        mirrorDeletes = (try? c.decode(Bool.self, forKey: .mirrorDeletes)) ?? false
        lastBackup = try? c.decode(Date.self, forKey: .lastBackup)
        lastPending = try? c.decode(Int.self, forKey: .lastPending)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }

    /// Mac 文件夹的名字（显示用）。
    var macName: String { (macPath as NSString).lastPathComponent }

    /// 「盘名 / 文件夹」或只有盘名（备份放在硬盘根目录时）。
    var driveLabel: String {
        driveRelativePath.isEmpty ? volumeName : "\(volumeName) / \(driveRelativePath)"
    }
}

/// 存在 UserDefaults 里的整份数据（带版本号）。
struct BackupPairsFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var pairs: [BackupPair]

    init(version: Int = BackupPairsFile.currentVersion, pairs: [BackupPair]) {
        self.version = version
        self.pairs = pairs
    }

    private enum CodingKeys: String, CodingKey { case version, pairs }

    /// 一组读不出来（字段坏了）只丢那一组，不连累别的。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        let lossy = (try? c.decode([LossyPair].self, forKey: .pairs)) ?? []
        pairs = lossy.compactMap(\.pair)
    }

    private struct LossyPair: Decodable {
        let pair: BackupPair?
        init(from decoder: Decoder) throws { pair = try? BackupPair(from: decoder) }
    }
}

enum BackupPairsCodec {
    /// 读：读不出来就是空的；相对路径不合规（含 ..）或 Mac 路径不是绝对路径的配对丢掉；同一个 id 只留第一组。
    static func decode(_ data: Data?) -> [BackupPair] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(BackupPairsFile.self, from: data) else { return [] }
        var seen = Set<UUID>()
        return file.pairs.compactMap { pair -> BackupPair? in
            guard pair.macPath.hasPrefix("/"), seen.insert(pair.id).inserted,
                  let rel = FolderBackupLogic.sanitizedRelative(pair.driveRelativePath) else { return nil }
            var cleaned = pair
            cleaned.driveRelativePath = rel
            return cleaned
        }
    }

    static func encode(_ pairs: [BackupPair]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(BackupPairsFile(pairs: pairs))
    }
}

// MARK: - 硬盘

/// 一块挂载着的卷（只取认盘要用的几项）。
struct BackupVolumeInfo: Equatable {
    /// 挂载点（/Volumes/盘名）。
    let mountPath: String
    let uuid: String?
    let name: String
    let capacity: Int64
    /// 外接的（移动硬盘、U 盘、SD 卡……）；启动盘和内置的其他分区为 false。
    let isExternal: Bool
}

/// 新建配对时哪里不对。
enum BackupPairProblem: Equatable {
    /// 硬盘那边选的不是外接磁盘上的文件夹。
    case driveNotExternal
    /// 两边是同一个文件夹。
    case sameFolder
    /// 硬盘文件夹在 Mac 文件夹里面（会越备份越大）。
    case driveInsideMac
    /// Mac 文件夹在硬盘文件夹里面。
    case macInsideDrive
    /// 已经有一模一样的配对。
    case duplicate

    var message: String {
        switch self {
        case .driveNotExternal: return String(localized: "备份位置要选移动硬盘、U 盘这类外接磁盘上的文件夹。")
        case .sameFolder: return String(localized: "Mac 文件夹和硬盘文件夹不能是同一个。")
        case .driveInsideMac: return String(localized: "硬盘文件夹不能放在要备份的 Mac 文件夹里面。")
        case .macInsideDrive: return String(localized: "要备份的文件夹已经在这块硬盘的备份文件夹里面了。")
        case .duplicate: return String(localized: "已经有一组一样的配对了。")
        }
    }
}

/// 插上配对的硬盘、检查完以后做什么。
enum BackupMountAction: Equatable {
    case nothing
    /// 弹提示：「有 N 个新文件/改动要备份到 盘名」（预览 / 备份 / 以后）。
    case prompt(Int)
    /// 插上就自动备份（不删除硬盘上的任何东西）。
    case autoBackup(Int)
}

enum FolderBackupLogic {
    /// 修改时间差这么多秒以内算一样（FAT 的精度是 2 秒）。
    static let mtimeTolerance: TimeInterval = 2
    /// 拷贝前硬盘至少要多留这么多空间。
    static let spaceMargin: Int64 = 64 * 1024 * 1024

    // MARK: 路径

    /// 标准化的绝对路径：去掉末尾的 /、. 和 ..（不解析替身 / 符号链接）。
    static func standardized(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    /// child 在 parent 里面（或就是 parent）。不分大小写（Mac 的磁盘默认不分大小写），只按整段路径比。
    static func isInside(_ child: String, _ parent: String) -> Bool {
        let c = standardized(child).lowercased()
        let p = standardized(parent).lowercased()
        if c == p { return true }
        let prefix = p == "/" ? "/" : p + "/"
        return c.hasPrefix(prefix)
    }

    /// 相对路径的安全版本：去掉多余的 /；含 .. 或 . 的整段、或带空字符的，返回 nil（不允许跳出根目录）。"" 合法。
    static func sanitizedRelative(_ rel: String) -> String? {
        if rel.contains("\0") { return nil }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains(where: { $0 == ".." || $0 == "." }) { return nil }
        return parts.joined(separator: "/")
    }

    /// path 相对于硬盘挂载点的路径（不在这块盘上返回 nil）。
    static func relativePath(of path: String, inVolume mountPath: String) -> String? {
        let p = standardized(path)
        let m = standardized(mountPath)
        guard isInside(p, m) else { return nil }
        if p.count <= m.count { return "" }
        let start = p.index(p.startIndex, offsetBy: m == "/" ? 1 : m.count + 1)
        return sanitizedRelative(String(p[start...]))
    }

    /// 这块卷是不是这组配对的硬盘：有 UUID 就只认 UUID（改了名也认得，同名的别的盘不认）；
    /// 没有 UUID 时退回「名字 + 容量」都一样。
    static func matches(_ pair: BackupPair, volume: BackupVolumeInfo) -> Bool {
        if let want = pair.volumeUUID, !want.isEmpty {
            guard let have = volume.uuid else { return false }
            return have.caseInsensitiveCompare(want) == .orderedSame
        }
        return !pair.volumeName.isEmpty && volume.name == pair.volumeName
            && pair.volumeCapacity > 0 && volume.capacity == pair.volumeCapacity
    }

    /// 这组配对的硬盘文件夹现在在哪（硬盘挂在 mountPath）。
    static func driveRoot(for pair: BackupPair, volumeMount mountPath: String) -> String? {
        guard let rel = sanitizedRelative(pair.driveRelativePath) else { return nil }
        let mount = standardized(mountPath)
        return rel.isEmpty ? mount : (mount as NSString).appendingPathComponent(rel)
    }

    /// 新建配对前检查。drivePath 所在的卷是 driveVolume（读不到传 nil）。
    static func validate(macPath: String, drivePath: String, driveVolume: BackupVolumeInfo?,
                         existing: [BackupPair] = []) -> BackupPairProblem? {
        guard let volume = driveVolume, volume.isExternal else { return .driveNotExternal }
        let mac = standardized(macPath)
        let drive = standardized(drivePath)
        if mac.lowercased() == drive.lowercased() { return .sameFolder }
        if isInside(drive, mac) { return .driveInsideMac }
        if isInside(mac, drive) { return .macInsideDrive }
        let rel = relativePath(of: drive, inVolume: volume.mountPath) ?? ""
        let duplicate = existing.contains { pair in
            standardized(pair.macPath).lowercased() == mac.lowercased()
                && pair.driveRelativePath.lowercased() == rel.lowercased()
                && matches(pair, volume: volume)
        }
        return duplicate ? .duplicate : nil
    }

    // MARK: 比较

    /// 大小一样、修改时间差 2 秒以内：算同一个版本。
    static func isSame(_ a: BackupEntry, _ b: BackupEntry) -> Bool {
        a.size == b.size && abs(a.modified.timeIntervalSince(b.modified)) <= mtimeTolerance
    }

    /// 路径的每一层上级（"a/b/c" → ["a", "a/b"]）。
    static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[0..<$0].joined(separator: "/") }
    }

    /// 比较两边，得出要做的事。只读，什么都不改。
    static func plan(mac: [String: BackupEntry], drive: [String: BackupEntry], leftoverTemps: [String] = []) -> BackupPlan {
        var plan = BackupPlan()
        var conflictSet = Set<String>()
        func underConflict(_ path: String) -> Bool {
            conflictSet.contains(path) || ancestors(of: path).contains { conflictSet.contains($0) }
        }

        // 排序后上级一定在下级前面（"a" 比 "a/b" 短，前缀相同时短的在前）。
        for path in mac.keys.sorted() {
            guard let m = mac[path], !underConflict(path) else { continue }
            if let d = drive[path] {
                if (m.kind == .folder) != (d.kind == .folder) {
                    // 一边是文件夹、一边是文件：要删掉一边才能对上，默认不删，跳过并列出来。
                    plan.conflicts.append(path)
                    conflictSet.insert(path)
                    continue
                }
                if m.kind == .folder { continue }
                if !isSame(m, d) { plan.changed.append(BackupChange(mac: m, drive: d)) }
            } else if m.kind == .folder {
                plan.foldersToCreate.append(path)
            } else {
                plan.newFiles.append(m)
            }
        }

        // 只在硬盘上的：只列最上面一层（文件夹里面的不再一个个列），另外数一下文件个数。
        var topOnly = Set<String>()
        for path in drive.keys.sorted() where mac[path] == nil {
            guard let d = drive[path], !underConflict(path) else { continue }
            if ancestors(of: path).contains(where: { topOnly.contains($0) }) {
                if d.kind != .folder { plan.onlyOnDriveFileCount += 1 }
                continue
            }
            topOnly.insert(path)
            plan.onlyOnDrive.append(d)
            if d.kind != .folder { plan.onlyOnDriveFileCount += 1 }
        }
        plan.leftoverTemps = leftoverTemps.filter { BackupJunk.isTempName(($0 as NSString).lastPathComponent) }
        return plan
    }

    // MARK: 删除的闸门

    /// 这次能不能删除硬盘上的东西：配对打开了镜像，并且用户这次在红色确认框里点了确认。两样缺一样都不删。
    static func deletionAllowed(pair: BackupPair, userConfirmed: Bool) -> Bool {
        pair.mirrorDeletes && userConfirmed
    }

    // MARK: 空间

    /// 拷贝要用的硬盘空间：新文件全算；改动的先拷一份临时文件再替换，按「新旧差值」算，再加上最大的一个改动文件。
    static func requiredBytes(_ plan: BackupPlan) -> Int64 {
        let new = plan.newFiles.reduce(Int64(0)) { $0 + $1.size }
        let growth = plan.changed.reduce(Int64(0)) { $0 + max(0, $1.mac.size - $1.drive.size) }
        let largestChanged = plan.changed.map(\.mac.size).max() ?? 0
        return new + growth + largestChanged
    }

    static func hasEnoughSpace(required: Int64, available: Int64, margin: Int64 = spaceMargin) -> Bool {
        required <= 0 || available >= required + margin
    }

    // MARK: 插上硬盘

    /// 插上配对的硬盘、检查完以后：没打开、不是 Pro、没有要备份的 → 什么都不做；打开了自动备份 → 直接备份；否则弹提示。
    /// 只在硬盘上的文件不算「要备份」（不会因为它们弹提示）。
    static func mountAction(pair: BackupPair, isPro: Bool, pendingCount: Int) -> BackupMountAction {
        guard isPro, pair.enabled, pendingCount > 0 else { return .nothing }
        return pair.autoBackupOnMount ? .autoBackup(pendingCount) : .prompt(pendingCount)
    }

    /// 提示的正文。
    static func promptText(count: Int, driveName: String) -> String {
        String(localized: "有 \(count) 个新文件/改动要备份到「\(driveName)」")
    }
}

// MARK: - 文件清单

/// 一个文件夹里的一项（路径相对于配对的根文件夹）。
struct BackupEntry: Equatable {
    enum Kind: Equatable { case file, folder, symlink }

    let path: String
    let kind: Kind
    let size: Int64
    let modified: Date
}

/// 一边的扫描结果。
struct BackupSnapshot: Equatable {
    var rootExists = false
    var entries: [String: BackupEntry] = [:]
    /// 只在 iCloud 云端、本机没有下载的文件（跳过，不触发下载）。
    var cloudOnly = 0
    /// 上次被打断留下的拾掇临时文件（硬盘那边扫到的，备份开始时清掉）。
    var leftoverTemps: [String] = []
    var cancelled = false

    var fileCount: Int { entries.values.filter { $0.kind != .folder }.count }
}

/// 不备份、也不算「只在硬盘上」的系统杂项。
enum BackupJunk {
    /// 拾掇拷贝时用的临时文件名前缀（拷完改回真名；被打断留下的下次清掉）。
    static let tempPrefix = ".shiduo-backup-"

    static let names: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".apdisk", ".VolumeIcon.icns", ".com.apple.timemachine.donotpresent", "Icon\r",
        "Thumbs.db", "desktop.ini", "$RECYCLE.BIN", "System Volume Information",
    ]

    static func isTempName(_ name: String) -> Bool { name.hasPrefix(tempPrefix) }

    /// 系统杂项：.DS_Store、AppleDouble（._开头）、废纸篓 / 索引文件夹、Office / LibreOffice 的锁文件、拾掇自己的临时文件。
    static func isJunk(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("._") || name.hasPrefix("~$") || name.hasPrefix(".~lock.")
            || isTempName(name)
    }
}

/// 取消标记（后台线程读，主线程写）。
final class BackupCancelFlag: @unchecked Sendable {
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

enum BackupScanner {
    /// 本机没下载的 iCloud 文件（stat 的 st_flags 里 SF_DATALESS）。
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// 列出 root 里面所有的文件和文件夹（含隐藏文件、包内容；不跟随符号链接；跳过系统杂项）。会阻塞，在后台线程调用。
    static func scan(_ root: String, skipCloudOnly: Bool = true, cancel: BackupCancelFlag? = nil) -> BackupSnapshot {
        var snapshot = BackupSnapshot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return snapshot }
        snapshot.rootExists = true
        guard let enumerator = fm.enumerator(atPath: root) else { return snapshot }
        var counter = 0
        while let next = enumerator.nextObject() as? String {
            counter += 1
            if counter % 512 == 0, cancel?.isCancelled == true {
                snapshot.cancelled = true
                break
            }
            let name = (next as NSString).lastPathComponent
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            if BackupJunk.isJunk(name) {
                if BackupJunk.isTempName(name), type == .typeRegular || type == .typeSymbolicLink {
                    snapshot.leftoverTemps.append(next)
                }
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            guard let rel = FolderBackupLogic.sanitizedRelative(next), !rel.isEmpty else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if type == .typeDirectory {
                snapshot.entries[rel] = BackupEntry(path: rel, kind: .folder, size: 0, modified: modified)
            } else if type == .typeSymbolicLink {
                snapshot.entries[rel] = BackupEntry(path: rel, kind: .symlink, size: size, modified: modified)
            } else if type == .typeRegular {
                if skipCloudOnly, isDataless((root as NSString).appendingPathComponent(next)) {
                    snapshot.cloudOnly += 1
                    continue
                }
                snapshot.entries[rel] = BackupEntry(path: rel, kind: .file, size: size, modified: modified)
            }
            // 其他（套接字、管道、设备文件）：不备份。
        }
        return snapshot
    }

    private static func isDataless(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return UInt32(info.st_flags) & datalessFlag != 0
    }
}

// MARK: - 计划和步骤

/// Mac 上改过、硬盘上有旧版本的文件。
struct BackupChange: Equatable {
    let mac: BackupEntry
    let drive: BackupEntry

    /// 硬盘上那份反而更新（预览里标出来；备份时仍以 Mac 为准）。
    var driveIsNewer: Bool {
        drive.modified.timeIntervalSince(mac.modified) > FolderBackupLogic.mtimeTolerance
    }
}

/// 比较两边得出的结果。
struct BackupPlan: Equatable {
    /// 硬盘上要新建的文件夹（含空文件夹），上级在前。
    var foldersToCreate: [String] = []
    /// 硬盘上没有的文件。
    var newFiles: [BackupEntry] = []
    /// 两边都有、但大小或修改时间不一样的文件。
    var changed: [BackupChange] = []
    /// 只在硬盘上的（最上面一层）。默认只列出来，不删、也不拷回 Mac。
    var onlyOnDrive: [BackupEntry] = []
    /// 只在硬盘上的文件总数（含文件夹里面的）。
    var onlyOnDriveFileCount = 0
    /// 一边是文件夹、一边是文件：跳过。
    var conflicts: [String] = []
    /// 上次被打断留下的拾掇临时文件。
    var leftoverTemps: [String] = []

    /// 要备份的个数（新文件 + 改动）。
    var pendingCount: Int { newFiles.count + changed.count }

    var bytesToCopy: Int64 {
        newFiles.reduce(Int64(0)) { $0 + $1.size } + changed.reduce(Int64(0)) { $0 + $1.mac.size }
    }

    /// 要不要动手（只差几个空文件夹也算）。
    var hasWork: Bool { pendingCount > 0 || !foldersToCreate.isEmpty }

    /// 按顺序要做的步骤：清临时文件 → 建文件夹 → 拷贝（新文件在前）→（只有 includeDeletes 时）移到硬盘废纸篓。
    /// includeDeletes 应该来自 FolderBackupLogic.deletionAllowed（镜像打开 + 这次确认过）。
    func steps(includeDeletes: Bool) -> [BackupStep] {
        var steps = leftoverTemps.map(BackupStep.removeLeftover)
        steps += foldersToCreate.map(BackupStep.makeFolder)
        steps += newFiles.map { BackupStep.copy($0.path, size: $0.size) }
        steps += changed.map { BackupStep.copy($0.mac.path, size: $0.mac.size) }
        if includeDeletes { steps += onlyOnDrive.map { BackupStep.trash($0.path) } }
        return steps
    }
}

/// 一步。只带相对路径：从哪拷、拷到哪只能由 BackupRoots 决定（Mac → 硬盘，方向写死）。
enum BackupStep: Equatable {
    /// 在硬盘文件夹里建文件夹。
    case makeFolder(String)
    /// Mac 文件夹里的这个文件 → 硬盘文件夹里的同一个位置（有旧的就替换）。
    case copy(String, size: Int64)
    /// 硬盘文件夹里的这一项 → 硬盘的废纸篓（只有镜像 + 确认过才会出现）。
    case trash(String)
    /// 硬盘文件夹里上次被打断留下的拾掇临时文件 → 删掉。
    case removeLeftover(String)
}

/// 一组配对两边的根文件夹。方向写死：读只读 mac，写只写 drive。
struct BackupRoots: Equatable {
    let mac: String
    let drive: String

    /// 两边必须是绝对路径、互不包含（同一个文件夹或一个在另一个里面都不行）。
    init?(mac: String, drive: String) {
        let m = FolderBackupLogic.standardized(mac)
        let d = FolderBackupLogic.standardized(drive)
        guard m.hasPrefix("/"), d.hasPrefix("/"), m != "/", d != "/",
              !FolderBackupLogic.isInside(m, d), !FolderBackupLogic.isInside(d, m) else { return nil }
        self.mac = m
        self.drive = d
    }

    /// 拷贝的来源：只会在 Mac 文件夹里。
    func source(_ rel: String) -> URL? {
        guard let clean = FolderBackupLogic.sanitizedRelative(rel), !clean.isEmpty else { return nil }
        return URL(fileURLWithPath: (mac as NSString).appendingPathComponent(clean))
    }

    /// 写入的位置：只会在硬盘文件夹里。
    func target(_ rel: String) -> URL? {
        guard let clean = FolderBackupLogic.sanitizedRelative(rel), !clean.isEmpty else { return nil }
        return URL(fileURLWithPath: (drive as NSString).appendingPathComponent(clean))
    }

    /// 能不能往这里写 / 删：在硬盘文件夹里面（不是它本身），并且不在 Mac 文件夹里。
    func isWritable(_ url: URL) -> Bool {
        let path = FolderBackupLogic.standardized(url.path)
        return FolderBackupLogic.isInside(path, drive) && path.lowercased() != drive.lowercased()
            && !FolderBackupLogic.isInside(path, mac)
    }
}

// MARK: - 执行

/// 执行器用到的文件操作（App 里用 copyfile + 系统废纸篓，测试里用 FileManager）。
struct BackupIO {
    /// 把 from 完整拷到 to（to 还不存在）。onBytes 报告这一个文件已拷的字节数。
    var copyItem: (_ from: URL, _ to: URL, _ onBytes: @escaping (Int64) -> Void) throws -> Void
    /// 移到废纸篓（硬盘自己的废纸篓）。做不到就抛错，绝不直接删除。
    var trashItem: (_ url: URL) throws -> Void
    /// 硬盘还接着吗（拷贝失败时用来区分「硬盘被拔了」和「这个文件拷不了」）。
    var isDriveAvailable: () -> Bool

    /// FileManager 版（单元测试用）。
    static let basic = BackupIO(
        copyItem: { from, to, _ in try FileManager.default.copyItem(at: from, to: to) },
        trashItem: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
        isDriveAvailable: { true }
    )
}

struct BackupProgress: Equatable {
    var filesDone = 0
    var fileCount = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var currentName = ""
}

struct BackupRunResult: Equatable {
    var copied = 0
    var copiedBytes: Int64 = 0
    var foldersCreated = 0
    var failed: [String] = []
    var trashed = 0
    /// 没能移到废纸篓的（留在硬盘上，没有直接删）。
    var trashFailed: [String] = []
    var cancelled = false
    var driveDisconnected = false
    /// 根本没开始：Mac 文件夹不在了，或者两边路径不合规。
    var refused = false
}

enum BackupExecutor {
    /// 一步步做。会阻塞，在后台线程调用。
    /// allowDeletes 必须来自 FolderBackupLogic.deletionAllowed：为 false 时就算步骤里有 trash 也一律跳过。
    static func run(_ steps: [BackupStep], roots: BackupRoots, allowDeletes: Bool, io: BackupIO,
                    cancel: BackupCancelFlag, progress: @escaping (BackupProgress) -> Void) -> BackupRunResult {
        let fm = FileManager.default
        var result = BackupRunResult()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: roots.mac, isDirectory: &isDir), isDir.boolValue else {
            result.refused = true
            return result
        }
        guard io.isDriveAvailable() else {
            result.driveDisconnected = true
            return result
        }
        do {
            try fm.createDirectory(atPath: roots.drive, withIntermediateDirectories: true)
        } catch {
            result.driveDisconnected = !io.isDriveAvailable()
            result.refused = !result.driveDisconnected
            return result
        }

        var state = BackupProgress()
        for step in steps {
            if case .copy(_, let size) = step {
                state.fileCount += 1
                state.bytesTotal += size
            }
        }
        progress(state)

        for step in steps {
            if cancel.isCancelled {
                result.cancelled = true
                break
            }
            switch step {
            case .removeLeftover(let rel):
                guard let url = roots.target(rel), roots.isWritable(url),
                      BackupJunk.isTempName(url.lastPathComponent) else { continue }
                try? fm.removeItem(at: url)

            case .makeFolder(let rel):
                guard let url = roots.target(rel), roots.isWritable(url) else { continue }
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    result.foldersCreated += 1
                } catch {
                    if !io.isDriveAvailable() {
                        result.driveDisconnected = true
                        return result
                    }
                }

            case .copy(let rel, let size):
                state.currentName = (rel as NSString).lastPathComponent
                progress(state)
                let base = state.bytesDone
                let outcome = copyOne(rel, roots: roots, io: io) { bytes in
                    var live = state
                    live.bytesDone = base + min(max(bytes, 0), size)
                    progress(live)
                }
                state.filesDone += 1
                state.bytesDone = base + size
                switch outcome {
                case .copied:
                    result.copied += 1
                    result.copiedBytes += size
                case .failed:
                    if cancel.isCancelled {
                        result.cancelled = true
                    } else if !io.isDriveAvailable() {
                        result.driveDisconnected = true
                    } else {
                        result.failed.append(rel)
                    }
                }
                progress(state)
                if result.cancelled || result.driveDisconnected { return result }

            case .trash(let rel):
                guard allowDeletes, let url = roots.target(rel), roots.isWritable(url) else { continue }
                do {
                    try io.trashItem(url)
                    result.trashed += 1
                } catch {
                    if !io.isDriveAvailable() {
                        result.driveDisconnected = true
                        return result
                    }
                    result.trashFailed.append(rel)
                }
            }
        }
        progress(state)
        return result
    }

    private enum CopyOutcome { case copied, failed }

    /// 拷一个文件：先拷成同目录下的临时文件，带上原来的修改时间，再改名替换（旧版本到最后一刻都还在，拔盘也不会只剩半个文件）。
    private static func copyOne(_ rel: String, roots: BackupRoots, io: BackupIO, onBytes: @escaping (Int64) -> Void) -> CopyOutcome {
        let fm = FileManager.default
        guard let from = roots.source(rel), let to = roots.target(rel), roots.isWritable(to) else { return .failed }
        let parent = to.deletingLastPathComponent()
        guard roots.isWritable(parent) || FolderBackupLogic.standardized(parent.path).lowercased() == roots.drive.lowercased() else {
            return .failed
        }
        // 来源必须还在 Mac 文件夹里（扫描后被删掉的就跳过）。
        guard (try? fm.attributesOfItem(atPath: from.path)) != nil else { return .failed }
        let temp = parent.appendingPathComponent(BackupJunk.tempPrefix + UUID().uuidString + ".tmp")
        guard roots.isWritable(temp) else { return .failed }
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try io.copyItem(from, temp, onBytes)
            let source = try fm.attributesOfItem(atPath: from.path)
            let isLink = (source[.type] as? FileAttributeType) == .typeSymbolicLink
            if !isLink, let date = source[.modificationDate] as? Date {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: temp.path)
            }
            // 目标是文件夹时不替换（计划里已经排除了，这里再保险一次）。
            var targetIsDir: ObjCBool = false
            if fm.fileExists(atPath: to.path, isDirectory: &targetIsDir), targetIsDir.boolValue,
               (try? fm.destinationOfSymbolicLink(atPath: to.path)) == nil {
                throw CocoaError(.fileWriteFileExists)
            }
            guard rename(temp.path, to.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return .copied
        } catch {
            try? fm.removeItem(at: temp)
            return .failed
        }
    }
}
