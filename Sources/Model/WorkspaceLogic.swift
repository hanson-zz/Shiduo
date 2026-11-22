import Foundation
import UniformTypeIdentifiers

// 拾掇 Pro「工作区」的模型和纯逻辑（单元测试也编译这个文件，只依赖 Foundation）。
//
// 一个工作区 = 若干个「来源」文件夹（本地、iCloud 云盘、外接硬盘都行）。工作区只记位置：
// 书签 + 最后的路径 + 卷 UUID / 相对路径（外接硬盘），从不移动、复制、改动原文件。
// 存在 UserDefaults 的 "workspaces" 键里（带版本号的 JSON，和「备份到硬盘」的配对一样），
// 读的时候宽松解码：缺的字段用默认值，认不出的字段忽略，一个工作区坏了只丢那一个。
// 文件夹墙（pinnedFolders）保持原样，不迁移、不改。

// MARK: - 模型

/// 文件分成四类（分段标签和「分类」卡片用）；文件夹单独数。
enum WorkspaceFileKind: String, Codable, CaseIterable, Hashable {
    case image
    case document
    case video
    case other
}

/// 来源在哪（来源卡片上的小字：桌面 / 文稿 / 下载 / iCloud 云盘 / 外接硬盘 / 本地）。
enum WorkspaceSourceKind: String, Codable, Hashable {
    case local
    case desktop
    case documents
    case downloads
    case iCloud
    case external
}

/// 最近文件 / 分段标签里的一个文件（扫描时记下的，不是实时的）。
struct WorkspaceFileEntry: Codable, Equatable, Hashable {
    var path: String
    var name: String
    var modified: Date
    var bytes: Int64
    var kind: WorkspaceFileKind
    /// 只在 iCloud 云端、本机没下载：不取缩略图、不预览、不打包，免得触发下载。
    var cloudOnly: Bool
    /// 文件夹（「文件夹」标签里的条目）。
    var isFolder: Bool

    init(path: String, name: String, modified: Date, bytes: Int64, kind: WorkspaceFileKind,
         cloudOnly: Bool = false, isFolder: Bool = false) {
        self.path = path
        self.name = name
        self.modified = modified
        self.bytes = bytes
        self.kind = kind
        self.cloudOnly = cloudOnly
        self.isFolder = isFolder
    }

    private enum CodingKeys: String, CodingKey { case path, name, modified, bytes, kind, cloudOnly, isFolder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = (try? c.decode(String.self, forKey: .name)) ?? (path as NSString).lastPathComponent
        modified = (try? c.decode(Date.self, forKey: .modified)) ?? .distantPast
        bytes = (try? c.decode(Int64.self, forKey: .bytes)) ?? 0
        kind = (try? c.decode(WorkspaceFileKind.self, forKey: .kind)) ?? .other
        cloudOnly = (try? c.decode(Bool.self, forKey: .cloudOnly)) ?? false
        isFolder = (try? c.decode(Bool.self, forKey: .isFolder)) ?? false
    }
}

/// 一个来源上次扫描的统计（缓存：硬盘拔掉、离线时照样显示）。
struct WorkspaceSourceStats: Codable, Equatable {
    var fileCount = 0
    var folderCount = 0
    var bytes: Int64 = 0
    var images = 0
    var documents = 0
    var videos = 0
    var others = 0
    /// 只在云端的文件个数（算进总数，但不下载）。
    var cloudOnly = 0
    var lastModified: Date?
    var scannedAt = Date.distantPast
    /// 文件太多，扫到上限就停了（数字是「至少」）。
    var truncated = false
    /// 最近修改的几个文件（新的在前，最多 WorkspaceLogic.cachedRecentLimit 个）。
    var recent: [WorkspaceFileEntry] = []

    init() {}

    func count(_ kind: WorkspaceFileKind) -> Int {
        switch kind {
        case .image: return images
        case .document: return documents
        case .video: return videos
        case .other: return others
        }
    }

    mutating func add(_ kind: WorkspaceFileKind) {
        switch kind {
        case .image: images += 1
        case .document: documents += 1
        case .video: videos += 1
        case .other: others += 1
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fileCount, folderCount, bytes, images, documents, videos, others, cloudOnly, lastModified, scannedAt, truncated, recent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileCount = (try? c.decode(Int.self, forKey: .fileCount)) ?? 0
        folderCount = (try? c.decode(Int.self, forKey: .folderCount)) ?? 0
        bytes = (try? c.decode(Int64.self, forKey: .bytes)) ?? 0
        images = (try? c.decode(Int.self, forKey: .images)) ?? 0
        documents = (try? c.decode(Int.self, forKey: .documents)) ?? 0
        videos = (try? c.decode(Int.self, forKey: .videos)) ?? 0
        others = (try? c.decode(Int.self, forKey: .others)) ?? 0
        cloudOnly = (try? c.decode(Int.self, forKey: .cloudOnly)) ?? 0
        lastModified = try? c.decode(Date.self, forKey: .lastModified)
        scannedAt = (try? c.decode(Date.self, forKey: .scannedAt)) ?? .distantPast
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
        recent = WorkspaceLossy.decodeArray(WorkspaceFileEntry.self, c, .recent)
    }
}

/// 工作区里的一个来源：只记位置。
struct WorkspaceSource: Codable, Identifiable, Equatable {
    var id: UUID
    /// 普通书签（拾掇没开沙盒）：文件夹改名 / 挪地方后跟过去。
    var bookmark: Data?
    /// 上次解析出的路径（书签解析不了时兜底）。
    var path: String
    var kind: WorkspaceSourceKind
    /// 外接硬盘：卷 UUID、名字、容量（认盘用，和「备份到硬盘」同一套规则）、文件夹相对于硬盘根目录的路径。
    var volumeUUID: String?
    var volumeName: String?
    var volumeCapacity: Int64
    var relativePath: String?
    var added: Date
    /// 上次扫描的统计（缓存）。
    var stats: WorkspaceSourceStats?

    init(id: UUID = UUID(), bookmark: Data? = nil, path: String, kind: WorkspaceSourceKind = .local,
         volumeUUID: String? = nil, volumeName: String? = nil, volumeCapacity: Int64 = 0,
         relativePath: String? = nil, added: Date = Date(), stats: WorkspaceSourceStats? = nil) {
        self.id = id
        self.bookmark = bookmark
        self.path = path
        self.kind = kind
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.volumeCapacity = volumeCapacity
        self.relativePath = relativePath
        self.added = added
        self.stats = stats
    }

    /// 显示的名字：文件夹名。
    var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// 在外接硬盘上（拔掉后显示「硬盘未连接」）。
    var isOnExternalVolume: Bool { kind == .external || !(volumeUUID ?? "").isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, bookmark, path, kind, volumeUUID, volumeName, volumeCapacity, relativePath, added, stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        bookmark = try? c.decode(Data.self, forKey: .bookmark)
        path = try c.decode(String.self, forKey: .path)
        // 以后版本加的新位置类型：这一版认不出就当「本地」。
        kind = (try? c.decode(WorkspaceSourceKind.self, forKey: .kind)) ?? .local
        volumeUUID = try? c.decode(String.self, forKey: .volumeUUID)
        volumeName = try? c.decode(String.self, forKey: .volumeName)
        volumeCapacity = (try? c.decode(Int64.self, forKey: .volumeCapacity)) ?? 0
        relativePath = try? c.decode(String.self, forKey: .relativePath)
        added = (try? c.decode(Date.self, forKey: .added)) ?? Date()
        stats = try? c.decode(WorkspaceSourceStats.self, forKey: .stats)
    }
}

struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 颜色：FolderPalette.colors 的下标（越界时按默认色）。
    var colorIndex: Int
    /// SF Symbol 名字（WorkspaceLogic.symbols 里的一个）。
    var symbol: String
    var sources: [WorkspaceSource]
    var created: Date

    init(id: UUID = UUID(), name: String, colorIndex: Int = WorkspaceLogic.defaultColorIndex,
         symbol: String = WorkspaceLogic.defaultSymbol, sources: [WorkspaceSource] = [], created: Date = Date()) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.symbol = symbol
        self.sources = sources
        self.created = created
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorIndex, symbol, sources, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        colorIndex = (try? c.decode(Int.self, forKey: .colorIndex)) ?? WorkspaceLogic.defaultColorIndex
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? WorkspaceLogic.defaultSymbol
        sources = WorkspaceLossy.decodeArray(WorkspaceSource.self, c, .sources)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }
}

/// UserDefaults 里存的整份数据（带版本号）。
struct WorkspacesFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var workspaces: [Workspace]
    /// 已经自动建过「默认工作区」（用户删光了也不再自动建）。
    var seededDefault: Bool

    init(version: Int = WorkspacesFile.currentVersion, workspaces: [Workspace] = [], seededDefault: Bool = false) {
        self.version = version
        self.workspaces = workspaces
        self.seededDefault = seededDefault
    }

    private enum CodingKeys: String, CodingKey { case version, workspaces, seededDefault }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        workspaces = WorkspaceLossy.decodeArray(Workspace.self, c, .workspaces)
        seededDefault = (try? c.decode(Bool.self, forKey: .seededDefault)) ?? !workspaces.isEmpty
    }
}

/// 数组里一项读不出来只丢那一项。
enum WorkspaceLossy {
    private struct Item<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func decodeArray<T: Decodable, K: CodingKey>(_ type: T.Type, _ c: KeyedDecodingContainer<K>, _ key: K) -> [T] {
        ((try? c.decode([Item<T>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

enum WorkspaceCodec {
    /// 读：读不出来就是空的（还没建过）；路径不是绝对路径的来源丢掉；同一个 id 只留第一个。
    static func decode(_ data: Data?) -> WorkspacesFile {
        guard let data else { return WorkspaceLogic.migrate(WorkspacesFile(version: WorkspacesFile.currentVersion)) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var file = try? decoder.decode(WorkspacesFile.self, from: data) else {
            return WorkspaceLogic.migrate(WorkspacesFile(version: WorkspacesFile.currentVersion))
        }
        var seenWorkspaces = Set<UUID>()
        file.workspaces = file.workspaces.compactMap { workspace -> Workspace? in
            guard seenWorkspaces.insert(workspace.id).inserted else { return nil }
            var cleaned = workspace
            if cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cleaned.name = WorkspaceLogic.defaultName
            }
            var seenSources = Set<UUID>()
            cleaned.sources = workspace.sources.compactMap { source -> WorkspaceSource? in
                guard source.path.hasPrefix("/"), seenSources.insert(source.id).inserted else { return nil }
                var s = source
                if let rel = s.relativePath { s.relativePath = FolderBackupLogic.sanitizedRelative(rel) }
                return s
            }
            return cleaned
        }
        return WorkspaceLogic.migrate(file)
    }

    static func encode(_ file: WorkspacesFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var out = file
        out.version = max(file.version, WorkspacesFile.currentVersion)
        return try? encoder.encode(out)
    }
}

// MARK: - 状态

/// 来源此刻能不能用。
enum WorkspaceSourceAvailability: Equatable {
    /// 在，路径是现在的位置（书签跟过去之后的）。
    case online(path: String)
    /// 外接硬盘没接上：保留记录和缓存，接上后自动恢复。
    case offline(volumeName: String)
    /// 找不到了（被删、被移到废纸篓、盘接上了但文件夹不在了）。
    case missing

    var path: String? {
        if case .online(let path) = self { return path }
        return nil
    }

    var isOnline: Bool { path != nil }
    var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

/// 加来源时哪里不对。
enum WorkspaceAddProblem: Equatable {
    case alreadyAdded(String)
    case insideExisting(String)
    case notFolder
}

/// 工作区里所有来源加起来的数字。
struct WorkspaceTotals: Equatable {
    var sources = 0
    var fileCount = 0
    var folderCount = 0
    var bytes: Int64 = 0
    var images = 0
    var documents = 0
    var videos = 0
    var others = 0
    var cloudOnly = 0
    var lastModified: Date?
    /// 有来源还没扫过（数字不全）。
    var incomplete = false

    func count(_ kind: WorkspaceFileKind) -> Int {
        switch kind {
        case .image: return images
        case .document: return documents
        case .video: return videos
        case .other: return others
        }
    }
}

// MARK: - 逻辑

enum WorkspaceLogic {
    static var defaultName: String { String(localized: "默认工作区") }
    /// FolderPalette.colors 里的「淡紫」。
    static let defaultColorIndex = 5
    static let defaultSymbol = "folder"
    static let maxNameLength = 60
    /// 缓存里每个来源记几个最近文件。
    static let cachedRecentLimit = 24

    /// 「修改图标」可选的符号。
    static let symbols: [String] = [
        "folder", "briefcase", "paintpalette", "camera", "film", "photo", "doc.text", "book",
        "music.note", "shippingbox", "hammer", "chart.bar", "person.2", "cart", "graduationcap",
        "star", "heart", "leaf", "airplane", "house",
    ]

    // MARK: 版本 / 迁移

    /// 读出来以后整理一遍：第一次用时建一个空的「默认工作区」；版本号补到当前版本。
    static func migrate(_ file: WorkspacesFile) -> WorkspacesFile {
        var out = file
        if !out.seededDefault {
            if out.workspaces.isEmpty {
                out.workspaces = [Workspace(name: defaultName)]
            }
            out.seededDefault = true
        }
        if out.version < WorkspacesFile.currentVersion { out.version = WorkspacesFile.currentVersion }
        return out
    }

    // MARK: 名字 / 排序

    /// 改名：去掉首尾空白和换行，太长截断；空的返回 nil（不改）。
    static func sanitizedName(_ raw: String) -> String? {
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// 新建工作区的名字：「新工作区」「新工作区 2」……不和已有的重名。
    static func newName(existing: [String]) -> String {
        let base = String(localized: "新工作区")
        let taken = Set(existing)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 拖动排序（和 SwiftUI 的 move(fromOffsets:toOffset:) 一样的含义）。
    static func move<T>(_ list: [T], from source: IndexSet, to destination: Int) -> [T] {
        let moving = source.sorted().filter { $0 >= 0 && $0 < list.count }
        guard !moving.isEmpty else { return list }
        var rest: [T] = []
        var picked: [T] = []
        for (i, element) in list.enumerated() {
            if moving.contains(i) { picked.append(element) } else { rest.append(element) }
        }
        let before = moving.filter { $0 < destination }.count
        let insertAt = min(max(destination - before, 0), rest.count)
        rest.insert(contentsOf: picked, at: insertAt)
        return rest
    }

    // MARK: 来源

    /// 来源在哪。isExternalVolume：所在的卷是外接的（BackupVolumeInfo.isExternal）。
    static func kind(forPath path: String, home: String, isExternalVolume: Bool) -> WorkspaceSourceKind {
        if isExternalVolume { return .external }
        let p = FolderBackupLogic.standardized(path)
        let h = FolderBackupLogic.standardized(home)
        if FolderBackupLogic.isInside(p, h + "/Library/Mobile Documents") { return .iCloud }
        if FolderBackupLogic.isInside(p, h + "/Desktop") { return .desktop }
        if FolderBackupLogic.isInside(p, h + "/Downloads") { return .downloads }
        if FolderBackupLogic.isInside(p, h + "/Documents") { return .documents }
        return .local
    }

    /// 新建一个来源（只做书签、记路径；volume 是文件夹所在的卷，读不到传 nil）。
    static func makeSource(url: URL, volume: BackupVolumeInfo?, home: String = NSHomeDirectory()) -> WorkspaceSource {
        let path = FolderBackupLogic.standardized(url.path)
        let external = volume?.isExternal ?? false
        var source = WorkspaceSource(
            bookmark: try? URL(fileURLWithPath: path, isDirectory: true).bookmarkData(),
            path: path,
            kind: kind(forPath: path, home: home, isExternalVolume: external)
        )
        if external, let volume {
            source.volumeUUID = volume.uuid
            source.volumeName = volume.name
            source.volumeCapacity = volume.capacity
            source.relativePath = FolderBackupLogic.relativePath(of: path, inVolume: volume.mountPath)
        }
        return source
    }

    /// 能不能加进这个工作区：同一个文件夹、已有来源里面的子文件夹不再加（数字会重复算）。
    static func addProblem(path: String, existing: [WorkspaceSource]) -> WorkspaceAddProblem? {
        let p = FolderBackupLogic.standardized(path)
        for source in existing {
            let s = FolderBackupLogic.standardized(source.path)
            if s.lowercased() == p.lowercased() { return .alreadyAdded(source.name) }
            if FolderBackupLogic.isInside(p, s) { return .insideExisting(source.name) }
        }
        return nil
    }

    /// 这块卷是不是来源所在的硬盘：有 UUID 只认 UUID；没有时「名字 + 容量」都一样才算（同「备份到硬盘」）。
    static func matches(_ source: WorkspaceSource, volume: BackupVolumeInfo) -> Bool {
        if let want = source.volumeUUID, !want.isEmpty {
            guard let have = volume.uuid else { return false }
            return have.caseInsensitiveCompare(want) == .orderedSame
        }
        guard let name = source.volumeName, !name.isEmpty else { return false }
        return volume.name == name && source.volumeCapacity > 0 && volume.capacity == source.volumeCapacity
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    /// 判定来源现在的状态。resolvedPath：书签解析出的路径（解析不了为 nil）；
    /// mounted：现在挂着的卷；isFolder：这个路径现在是不是一个文件夹。
    static func availability(of source: WorkspaceSource, resolvedPath: String?, mounted: [BackupVolumeInfo],
                             isFolder: (String) -> Bool) -> WorkspaceSourceAvailability {
        if source.isOnExternalVolume {
            guard let volume = mounted.first(where: { matches(source, volume: $0) }) else {
                return .offline(volumeName: source.volumeName ?? source.name)
            }
            // 盘接着：先信书签（文件夹在盘里改了名也认得，但只认同一块盘里的位置）。
            if let resolved = resolvedPath, !isInTrash(resolved),
               FolderBackupLogic.isInside(resolved, volume.mountPath), isFolder(resolved) {
                return .online(path: FolderBackupLogic.standardized(resolved))
            }
            if let rel = source.relativePath.flatMap(FolderBackupLogic.sanitizedRelative) {
                let mount = FolderBackupLogic.standardized(volume.mountPath)
                let candidate = rel.isEmpty ? mount : (mount as NSString).appendingPathComponent(rel)
                if isFolder(candidate) { return .online(path: candidate) }
            }
            return .missing
        }
        if let resolved = resolvedPath, !isInTrash(resolved), isFolder(resolved) {
            return .online(path: FolderBackupLogic.standardized(resolved))
        }
        if !isInTrash(source.path), isFolder(source.path) {
            return .online(path: FolderBackupLogic.standardized(source.path))
        }
        return .missing
    }

    // MARK: 统计

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "svg", "raw", "dng", "cr2", "nef", "arw",
        "psd", "ai", "sketch", "fig", "xd", "eps",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "3gp", "mts", "m2ts"]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "csv", "ppt", "pptx", "md", "txt", "rtf", "rtfd",
        "epub", "odt", "ods", "odp", "wps",
    ]

    /// 按扩展名和类型分类（设计稿 .psd / .ai / .sketch / .fig 算图片）。
    static func fileKind(ext rawExt: String, type: UTType?) -> WorkspaceFileKind {
        let ext = rawExt.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if documentExtensions.contains(ext) { return .document }
        if let type {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
                || type.conforms(to: .rtf) || type.conforms(to: .plainText) {
                return .document
            }
        }
        return .other
    }

    /// 把各个来源的统计加起来。缓存也算（离线时显示缓存值）；没扫过的来源记 incomplete。
    static func totals(_ stats: [WorkspaceSourceStats?]) -> WorkspaceTotals {
        var t = WorkspaceTotals()
        t.sources = stats.count
        for s in stats {
            guard let s else {
                t.incomplete = true
                continue
            }
            t.fileCount += s.fileCount
            t.folderCount += s.folderCount
            t.bytes += s.bytes
            t.images += s.images
            t.documents += s.documents
            t.videos += s.videos
            t.others += s.others
            t.cloudOnly += s.cloudOnly
            if let d = s.lastModified { t.lastModified = max(t.lastModified ?? d, d) }
        }
        return t
    }

    /// 合并几个来源的最近文件，新的在前。
    static func mergeRecent(_ lists: [[WorkspaceFileEntry]], limit: Int) -> [WorkspaceFileEntry] {
        var seen = Set<String>()
        return lists.joined()
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
            .filter { seen.insert($0.path).inserted }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: ZIP

    /// 不覆盖同名：「名字.zip」已有就「名字 2.zip」「名字 3.zip」……（和整理、暂存架压缩同一种编号）。
    static func uniqueURL(for name: String, in folder: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard exists(candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            n += 1
        } while exists(candidate.path)
        return candidate
    }

    /// ZIP 文件名：工作区名字里不能当文件名的字符换掉。
    static func zipName(for workspaceName: String) -> String {
        var name = workspaceName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if name.isEmpty { name = String(localized: "工作区") }
        return name + ".zip"
    }

    /// ZIP 里每个来源占一个顶层文件夹，名字重复时加编号。
    static func uniqueFolderNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { raw in
            var base = raw.replacingOccurrences(of: "/", with: "-")
            if base.isEmpty || base == "." || base == ".." { base = String(localized: "来源") }
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(n)"
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }
}

// MARK: - 扫描

/// 扫一个来源文件夹（后台线程里跑；isCancelled 返回 true 就停下，返回 nil）。
/// 只读元数据：只在云端的 iCloud 文件不会被下载（不读内容、不取缩略图）。
enum WorkspaceScanner {
    struct Result: Equatable {
        var stats: WorkspaceSourceStats
        /// 每类最新的若干个（分段标签里显示）。
        var byKind: [WorkspaceFileKind: [WorkspaceFileEntry]]
        /// 第一层子文件夹（「文件夹」标签里显示），新的在前。
        var folders: [WorkspaceFileEntry]
        /// 所有文件（不含只在云端的）的总数：打包 ZIP 前的确认用。
        var localFileCount: Int
        var localBytes: Int64
    }

    static let defaultMaxItems = 300_000
    static let perKindLimit = 200

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        .contentTypeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    static func isCloudOnly(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    static func scan(root: URL, now: Date = Date(), maxItems: Int = defaultMaxItems, recentLimit: Int = WorkspaceLogic.cachedRecentLimit,
                     isCancelled: () -> Bool = { false }) -> Result? {
        let fm = FileManager.default
        var stats = WorkspaceSourceStats()
        var byKind: [WorkspaceFileKind: [WorkspaceFileEntry]] = [:]
        var folders: [WorkspaceFileEntry] = []
        var recent: [WorkspaceFileEntry] = []
        var localFiles = 0
        var localBytes: Int64 = 0
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { return nil }
        var seen = 0

        func keepNewest(_ list: inout [WorkspaceFileEntry], _ entry: WorkspaceFileEntry, limit: Int) {
            list.append(entry)
            if list.count > limit * 2 {
                list.sort { $0.modified > $1.modified }
                list.removeLast(list.count - limit)
            }
        }

        while let next = enumerator.nextObject() as? URL {
            seen += 1
            if seen % 400 == 0, isCancelled() { return nil }
            if seen > maxItems {
                stats.truncated = true
                break
            }
            guard let v = try? next.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            let modified = v.contentModificationDate ?? .distantPast
            if v.isDirectory == true && v.isPackage != true {
                stats.folderCount += 1
                if enumerator.level == 1 {
                    let entry = WorkspaceFileEntry(path: next.path, name: next.lastPathComponent, modified: modified,
                                                   bytes: 0, kind: .other, cloudOnly: false, isFolder: true)
                    keepNewest(&folders, entry, limit: perKindLimit)
                }
                continue
            }
            let bytes = Int64(v.fileSize ?? 0)
            let cloud = isCloudOnly(v)
            let kind = WorkspaceLogic.fileKind(ext: next.pathExtension, type: v.contentType)
            stats.fileCount += 1
            stats.bytes += bytes
            stats.add(kind)
            if cloud {
                stats.cloudOnly += 1
            } else {
                localFiles += 1
                localBytes += bytes
            }
            if modified != .distantPast {
                stats.lastModified = max(stats.lastModified ?? modified, modified)
            }
            let entry = WorkspaceFileEntry(path: next.path, name: next.lastPathComponent, modified: modified,
                                           bytes: bytes, kind: kind, cloudOnly: cloud)
            keepNewest(&byKind[kind, default: []], entry, limit: perKindLimit)
            keepNewest(&recent, entry, limit: recentLimit)
        }
        if isCancelled() { return nil }
        for kind in WorkspaceFileKind.allCases {
            byKind[kind] = Array((byKind[kind] ?? []).sorted { $0.modified > $1.modified }.prefix(perKindLimit))
        }
        folders = Array(folders.sorted { $0.modified > $1.modified }.prefix(perKindLimit))
        stats.recent = Array(recent.sorted { $0.modified > $1.modified }.prefix(recentLimit))
        stats.scannedAt = now
        return Result(stats: stats, byKind: byKind, folders: folders, localFileCount: localFiles, localBytes: localBytes)
    }
}

// MARK: - 打包 ZIP

/// 把几个来源打成一个 ZIP（系统自带的 /usr/bin/zip）：每个来源一个顶层文件夹；
/// 只打本机上有的文件，只在 iCloud 云端的跳过（不触发下载）；不覆盖已有的 ZIP。
enum WorkspaceZip {
    struct Outcome: Equatable {
        var url: URL?
        var files = 0
        var skippedCloud = 0
        var cancelled = false
        var failed = false
    }

    /// 列出一个来源里要打包的文件（相对路径）；隐藏文件、只在云端的、名字里带换行的跳过。
    static func localFiles(root: URL, isCancelled: () -> Bool = { false }) -> (files: [String], skippedCloud: Int)? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        // 按相对路径列（不依赖系统返回的绝对路径前缀，/var 和 /private/var 这类写法不影响）。
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var files: [String] = []
        var skipped = 0
        var seen = 0
        while let rel = enumerator.nextObject() as? String {
            seen += 1
            if seen % 400 == 0, isCancelled() { return nil }
            let last = (rel as NSString).lastPathComponent
            if last.hasPrefix(".") {
                if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if rel.contains("\n") || rel.contains("\r") { continue }
            let url = root.appendingPathComponent(rel)
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true || v.isDirectory == true { continue }
            if WorkspaceScanner.isCloudOnly(v) {
                skipped += 1
                continue
            }
            files.append(rel)
        }
        return (files, skipped)
    }

    /// 打包。sources：(ZIP 里的顶层文件夹名, 来源文件夹)。target 已经是不重名的位置。
    static func make(sources: [(name: String, root: URL)], target: URL,
                     isCancelled: @escaping () -> Bool = { false }) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        let staging = fm.temporaryDirectory.appendingPathComponent("ShiduoWorkspaceZip-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            outcome.failed = true
            return outcome
        }
        let names = WorkspaceLogic.uniqueFolderNames(sources.map(\.name))
        var lines: [String] = []
        for (index, source) in sources.enumerated() {
            // 临时目录里放一个指向来源的替身（符号链接），zip 顺着它读，原文件不动、不拷贝。
            let link = staging.appendingPathComponent(names[index])
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: source.root)
            } catch {
                outcome.failed = true
                return outcome
            }
            guard let listed = localFiles(root: source.root, isCancelled: isCancelled) else {
                outcome.cancelled = true
                return outcome
            }
            outcome.skippedCloud += listed.skippedCloud
            lines.append(contentsOf: listed.files.map { names[index] + "/" + $0 })
        }
        if isCancelled() {
            outcome.cancelled = true
            return outcome
        }
        guard !lines.isEmpty else { return outcome }
        let listURL = fm.temporaryDirectory.appendingPathComponent("ShiduoWorkspaceZip-\(UUID().uuidString).txt")
        defer { try? fm.removeItem(at: listURL) }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        } catch {
            outcome.failed = true
            return outcome
        }
        // 先写到一个临时名字，成功了再改成正式名字：中途取消 / 失败不会留下半个 ZIP。
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).part")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        // -nw：名字里的 * ? [ ] 不当通配符。
        process.arguments = ["-q", "-nw", "-@", partial.path]
        process.standardInput = try? FileHandle(forReadingFrom: listURL)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            outcome.failed = true
            return outcome
        }
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                process.waitUntilExit()
                try? fm.removeItem(at: partial)
                outcome.cancelled = true
                return outcome
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0, fm.fileExists(atPath: partial.path) else {
            try? fm.removeItem(at: partial)
            outcome.failed = true
            return outcome
        }
        // 打包期间同名文件被别人建了：换一个编号，绝不覆盖。
        let final = WorkspaceLogic.uniqueURL(for: target.lastPathComponent, in: target.deletingLastPathComponent())
        do {
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            outcome.failed = true
            return outcome
        }
        outcome.url = final
        outcome.files = lines.count
        return outcome
    }
}
