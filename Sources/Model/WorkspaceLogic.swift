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
    /// 只在云端的文件加起来的大小（打包前估算本机大小时要减掉）。
    var cloudBytes: Int64 = 0
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
        case fileCount, folderCount, bytes, images, documents, videos, others, cloudOnly, cloudBytes, lastModified, scannedAt, truncated, recent
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
        cloudBytes = (try? c.decode(Int64.self, forKey: .cloudBytes)) ?? 0
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
    /// 这一版认不出的字段（以后版本加的）：原样留着，存的时候写回去。
    var unknownFields: [String: WorkspaceJSON] = [:]

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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, bookmark, path, kind, volumeUUID, volumeName, volumeCapacity, relativePath, added, stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        bookmark = try? c.decode(Data.self, forKey: .bookmark)
        path = try c.decode(String.self, forKey: .path)
        var extra = WorkspaceUnknownFields.decode(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
        // 以后版本加的新位置类型：这一版认不出就当「本地」（原来的值留在 unknownFields 里，存的时候写回去）。
        if let raw = try? c.decode(String.self, forKey: .kind), WorkspaceSourceKind(rawValue: raw) == nil {
            kind = .local
            extra["kind"] = .string(raw)
        } else {
            kind = (try? c.decode(WorkspaceSourceKind.self, forKey: .kind)) ?? .local
        }
        volumeUUID = try? c.decode(String.self, forKey: .volumeUUID)
        volumeName = try? c.decode(String.self, forKey: .volumeName)
        volumeCapacity = (try? c.decode(Int64.self, forKey: .volumeCapacity)) ?? 0
        relativePath = try? c.decode(String.self, forKey: .relativePath)
        added = (try? c.decode(Date.self, forKey: .added)) ?? Date()
        stats = try? c.decode(WorkspaceSourceStats.self, forKey: .stats)
        unknownFields = extra
    }

    func encode(to encoder: Encoder) throws {
        // 先写认不出的字段，再写这一版的字段（同名时这一版的值为准；认不出的位置类型写回原值）。
        try WorkspaceUnknownFields.encode(unknownFields, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(path, forKey: .path)
        if unknownFields["kind"] == nil || kind != .local { try c.encode(kind, forKey: .kind) }
        try c.encodeIfPresent(volumeUUID, forKey: .volumeUUID)
        try c.encodeIfPresent(volumeName, forKey: .volumeName)
        try c.encode(volumeCapacity, forKey: .volumeCapacity)
        try c.encodeIfPresent(relativePath, forKey: .relativePath)
        try c.encode(added, forKey: .added)
        try c.encodeIfPresent(stats, forKey: .stats)
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
    /// 这一版认不出的字段（以后版本加的）：原样留着，存的时候写回去。
    var unknownFields: [String: WorkspaceJSON] = [:]

    init(id: UUID = UUID(), name: String, colorIndex: Int = WorkspaceLogic.defaultColorIndex,
         symbol: String = WorkspaceLogic.defaultSymbol, sources: [WorkspaceSource] = [], created: Date = Date()) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.symbol = symbol
        self.sources = sources
        self.created = created
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, name, colorIndex, symbol, sources, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        colorIndex = (try? c.decode(Int.self, forKey: .colorIndex)) ?? WorkspaceLogic.defaultColorIndex
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? WorkspaceLogic.defaultSymbol
        sources = WorkspaceLossy.decodeArray(WorkspaceSource.self, c, .sources)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        unknownFields = WorkspaceUnknownFields.decode(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        try WorkspaceUnknownFields.encode(unknownFields, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorIndex, forKey: .colorIndex)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(sources, forKey: .sources)
        try c.encode(created, forKey: .created)
    }
}

/// UserDefaults 里存的整份数据（带版本号）。
struct WorkspacesFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var workspaces: [Workspace]
    /// 已经自动建过「默认工作区」（用户删光了也不再自动建）。
    var seededDefault: Bool
    /// 这一版认不出的字段（以后版本加的）：原样留着，存的时候写回去。
    var unknownFields: [String: WorkspaceJSON] = [:]

    init(version: Int = WorkspacesFile.currentVersion, workspaces: [Workspace] = [], seededDefault: Bool = false) {
        self.version = version
        self.workspaces = workspaces
        self.seededDefault = seededDefault
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, workspaces, seededDefault }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        workspaces = WorkspaceLossy.decodeArray(Workspace.self, c, .workspaces)
        seededDefault = (try? c.decode(Bool.self, forKey: .seededDefault)) ?? !workspaces.isEmpty
        unknownFields = WorkspaceUnknownFields.decode(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        try WorkspaceUnknownFields.encode(unknownFields, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(workspaces, forKey: .workspaces)
        try c.encode(seededDefault, forKey: .seededDefault)
    }
}

/// 任意 JSON 值（保留认不出的字段用）。
enum WorkspaceJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WorkspaceJSON])
    case object([String: WorkspaceJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([WorkspaceJSON].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: WorkspaceJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    var arrayValue: [WorkspaceJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: WorkspaceJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

/// 读 / 写认不出的字段。
enum WorkspaceUnknownFields {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func decode(_ decoder: Decoder, known: Set<String>) -> [String: WorkspaceJSON] {
        guard let c = try? decoder.container(keyedBy: AnyKey.self) else { return [:] }
        var out: [String: WorkspaceJSON] = [:]
        for key in c.allKeys where !known.contains(key.stringValue) {
            if let value = try? c.decode(WorkspaceJSON.self, forKey: key) { out[key.stringValue] = value }
        }
        return out
    }

    static func encode(_ fields: [String: WorkspaceJSON], to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in fields { try c.encode(value, forKey: AnyKey(key)) }
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

/// 从 UserDefaults 读出来的结果：要不要先备份原始数据、这次运行能不能写回去。
struct WorkspacesLoad {
    var file: WorkspacesFile
    /// 原始数据要先原样备份（读不出来、来自更新的版本、有工作区 / 来源读丢了）。
    var needsBackup = false
    /// 只读：数据来自更新版本的拾掇，这次运行一律不写回去（免得把新版本的数据改坏、丢字段）。
    var readOnly = false
    /// 要马上存一次（第一次用，刚建了默认工作区）。其他情况读完不存。
    var needsSave = false
}

enum WorkspaceCodec {
    /// 备份键的前缀：workspaces.backup.<时间>。
    static let backupPrefix = "workspaces.backup."

    static func backupKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return backupPrefix + formatter.string(from: date)
    }

    /// 启动时读配置：什么情况都不会拿默认值覆盖用户原来的数据。
    /// 读不出来（损坏）：先备份原始数据，这次用一个默认工作区，但不马上保存；
    /// 版本号比这一版新：备份 + 只读；有工作区 / 来源读丢了：备份（用户改了东西再存时原始数据还在备份里）。
    static func load(_ data: Data?) -> WorkspacesLoad {
        guard let data else { return WorkspacesLoad(file: decode(nil), needsSave: true) }
        let file = decode(data)
        guard let raw = try? JSONDecoder().decode(WorkspaceJSON.self, from: data), let top = raw.objectValue else {
            return WorkspacesLoad(file: file, needsBackup: true)
        }
        let version = Int(top["version"]?.numberValue ?? 0)
        let newer = version > WorkspacesFile.currentVersion
        let rawWorkspaces = top["workspaces"]?.arrayValue ?? []
        let rawSources = rawWorkspaces.reduce(0) { $0 + ($1.objectValue?["sources"]?.arrayValue?.count ?? 0) }
        let decodedSources = file.workspaces.reduce(0) { $0 + $1.sources.count }
        let lost = file.workspaces.count < rawWorkspaces.count || decodedSources < rawSources
        return WorkspacesLoad(file: file, needsBackup: newer || lost, readOnly: newer)
    }

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
    /// 新加的文件夹是已有来源的上层文件夹（父文件夹后加）：可以换成它（只移除那几个子来源的记录）。
    case containsExisting(ids: [UUID], names: [String])
    /// 范围太大（整个磁盘、用户文件夹、资源库）：会扫几十万个文件、连续弹权限框。
    case tooBroad
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

    /// 能不能加进这个工作区：同一个文件夹、已有来源里面的子文件夹不再加；
    /// 已有来源的上层文件夹要先问用户（换掉那几个子来源），不然数字、ZIP 会重复算。
    static func addProblem(path: String, existing: [WorkspaceSource], home: String = NSHomeDirectory()) -> WorkspaceAddProblem? {
        let p = FolderBackupLogic.standardized(path)
        if isTooBroad(p, home: home) { return .tooBroad }
        for source in existing {
            let s = FolderBackupLogic.standardized(source.path)
            if s.lowercased() == p.lowercased() { return .alreadyAdded(source.name) }
            if FolderBackupLogic.isInside(p, s) { return .insideExisting(source.name) }
        }
        let children = existing.filter { FolderBackupLogic.isInside($0.path, p) }
        if !children.isEmpty { return .containsExisting(ids: children.map(\.id), names: children.map(\.name)) }
        return nil
    }

    /// 范围太大的文件夹：根目录、/Users、/Volumes、系统目录、用户文件夹本身、资源库。
    static func isTooBroad(_ path: String, home: String) -> Bool {
        let p = FolderBackupLogic.standardized(path).lowercased()
        let h = FolderBackupLogic.standardized(home).lowercased()
        let broad = ["/", "/users", "/volumes", "/system", "/system/volumes/data", "/library", "/applications", "/private",
                     h, h + "/library"]
        return broad.contains(p)
    }

    /// 同一个工作区里落在别的来源里面的来源（来源 id → 包含它的来源的名字）。
    /// 统计、最近文件、打包都跳过它们，免得同一批文件算两遍；路径一样的只留前面那个。
    /// items 用来源此刻的路径（书签跟着改名 / 移动以后的）。
    static func nestedSources(_ items: [(id: UUID, path: String, name: String)]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        let paths = items.map { FolderBackupLogic.standardized($0.path).lowercased() }
        for (i, item) in items.enumerated() {
            for (j, other) in items.enumerated() where i != j && out[other.id] == nil {
                guard FolderBackupLogic.isInside(paths[i], paths[j]) else { continue }
                // 路径完全一样：只把后面的那个算重复。
                if paths[i] == paths[j] && j > i { continue }
                out[item.id] = other.name
                break
            }
        }
        return out
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

    /// 文件夹读不了时返回 errno（EPERM：系统「文件与文件夹」权限没给；EACCES：没有读权限；ENOENT：不在了），读得了返回 nil。
    static func readProblem(_ path: String) -> Int32? {
        guard let dir = opendir(path) else { return errno }
        closedir(dir)
        return nil
    }

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
                stats.cloudBytes += bytes
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

/// 一次正在跑的打包：App 退出时要能停掉压缩子进程、删掉临时文件（不在「下载」里留下隐藏的半个 ZIP）。
final class WorkspaceZipJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var partial: URL?
    private var stopped = false

    private static let registryLock = NSLock()
    private static var running: [ObjectIdentifier: WorkspaceZipJob] = [:]

    init() {}

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func attach(_ process: Process, partial: URL) {
        lock.lock()
        self.process = process
        self.partial = partial
        lock.unlock()
        Self.registryLock.lock()
        Self.running[ObjectIdentifier(self)] = self
        Self.registryLock.unlock()
    }

    func detach() {
        lock.lock()
        process = nil
        partial = nil
        lock.unlock()
        Self.registryLock.lock()
        Self.running[ObjectIdentifier(self)] = nil
        Self.registryLock.unlock()
    }

    /// 停下：结束压缩子进程（打包线程看到后会删临时文件）。
    func stop() {
        lock.lock()
        stopped = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// App 退出时用：停下子进程，最多等 2 秒让它退出，再直接删掉临时文件（打包线程可能来不及删）。
    func stopAndCleanUp() {
        stop()
        lock.lock()
        let p = process
        let part = partial
        lock.unlock()
        let deadline = Date().addingTimeInterval(2)
        while let p, p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if let part { try? FileManager.default.removeItem(at: part) }
    }

    /// App 退出：停掉所有正在跑的打包。
    static func stopAllForQuit() {
        registryLock.lock()
        let jobs = Array(running.values)
        registryLock.unlock()
        for job in jobs { job.stopAndCleanUp() }
    }
}

/// 把几个来源打成一个 ZIP（系统自带的 /usr/bin/bsdtar，文件名按 UTF-8 写并打上 UTF-8 标记，Windows 上中文名不乱码）：
/// 每个来源一个顶层文件夹；只打本机上有的文件，只在云端的跳过（不触发下载）；不覆盖已有的 ZIP。
/// 临时文件写在系统给的「替换用临时目录」（和目标同一块盘），不放在「下载」里。
enum WorkspaceZip {
    struct Outcome: Equatable {
        var url: URL?
        /// 打进去的文件个数（文件包算一个）。
        var files = 0
        var skippedCloud = 0
        /// 读不了的文件（打包时被删 / 改名、没有读权限）：已跳过，ZIP 照样留着。ZIP 里的路径。
        var unreadable: [String] = []
        /// 没能打包的来源（断开了、没有权限）：ZIP 里的顶层文件夹名。
        var unavailableSources: [String] = []
        var cancelled = false
        var failed = false
        /// 磁盘剩余空间不够了，中途停下（没有留下半个 ZIP）。
        var outOfSpace = false
    }

    /// 打包前：压缩前的大小 + 这么多余量，大于剩余空间就不开始。
    static let reserveBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// 打包过程中：目标磁盘剩余空间少于这个就停下。
    static let minimumFreeBytes: Int64 = 1024 * 1024 * 1024

    /// 剩余空间够不够（读不到剩余空间时不拦）。
    static func hasRoom(needed: Int64, available: Int64?) -> Bool {
        guard let available else { return true }
        return max(needed, 0) + reserveBytes <= available
    }

    /// 某个文件夹所在磁盘的剩余空间（「重要用途」口径：系统可以腾出来的也算）。
    static func availableCapacity(_ folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// 列出一个来源的结果。
    enum Listing: Equatable {
        /// files：要打包的相对路径（文件包里的文件逐个列出）；items：文件个数（文件包算一个）。
        case listed(files: [String], items: Int, skippedCloud: Int, unreadable: [String])
        case cancelled
        /// 来源打不开（断开了、被删了、没有权限）。
        case unavailable
    }

    private static let listKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// 相对路径：去掉来源根目录的前缀（/var 和 /private/var 这类写法都认）。
    private static func relativizer(_ root: URL) -> (URL) -> String? {
        let prefixes = Set([root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return { url in
            let path = url.path
            for prefix in prefixes where path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            return nil
        }
    }

    /// 列出一个来源里要打包的文件。规则和扫描一样：隐藏文件跳过、符号链接跳过、只在云端的跳过（不下载）、
    /// 文件包（.fcpbundle、.rtfd、.app……）整个打进去但只算一个；名字里带换行的跳过；没有读权限的记下来跳过。
    static func localFiles(root: URL, isCancelled: () -> Bool = { false }) -> Listing {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              WorkspaceScanner.readProblem(root.path) == nil,
              let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: listKeys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { return .unavailable }
        let relative = relativizer(root)
        var files: [String] = []
        var items = 0
        var skipped = 0
        var unreadable: [String] = []
        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            seen += 1
            if seen % 400 == 0, isCancelled() { return .cancelled }
            guard let v = try? url.resourceValues(forKeys: Set(listKeys)) else { continue }
            guard let rel = relative(url), !rel.isEmpty, !rel.contains("\n"), !rel.contains("\r") else {
                if v.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if v.isSymbolicLink == true { continue }
            if WorkspaceScanner.isCloudOnly(v) {
                skipped += 1
                if v.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if v.isDirectory == true {
                guard v.isPackage == true else { continue }
                guard let inner = packageFiles(url, rel: rel, isCancelled: isCancelled) else { return .cancelled }
                if inner.cloud > 0 {
                    // 包里有文件只在云端：整个包跳过（打半个包没意义，也不下载）。
                    skipped += 1
                    continue
                }
                files += inner.files
                unreadable += inner.unreadable
                items += 1
                continue
            }
            if access(url.path, R_OK) != 0 {
                unreadable.append(rel)
                continue
            }
            files.append(rel)
            items += 1
        }
        if isCancelled() { return .cancelled }
        return .listed(files: files, items: items, skippedCloud: skipped, unreadable: unreadable)
    }

    /// 文件包里的所有文件（包括包里的隐藏文件和符号链接，原样打包；符号链接不跟进去）。
    private static func packageFiles(_ package: URL, rel: String, isCancelled: () -> Bool)
        -> (files: [String], cloud: Int, unreadable: [String])? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return ([], 0, []) }
        let relative = relativizer(package)
        var files: [String] = []
        var cloud = 0
        var unreadable: [String] = []
        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            seen += 1
            if seen % 400 == 0, isCancelled() { return nil }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let inner = relative(url), !inner.isEmpty,
                  !inner.contains("\n"), !inner.contains("\r") else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true { continue }
            if v.isSymbolicLink != true && WorkspaceScanner.isCloudOnly(v) {
                cloud += 1
                continue
            }
            let path = rel + "/" + inner
            if v.isSymbolicLink != true && access(url.path, R_OK) != 0 {
                unreadable.append(path)
                continue
            }
            files.append(path)
        }
        return (files, cloud, unreadable)
    }

    /// bsdtar 的错误输出里，哪些是「某个文件读不了」（ZIP 照样有用）。
    /// 返回读不了的文件（ZIP 里的路径），onlyFileErrors：除此之外没有别的错误。
    static func unreadableFiles(stderr: String, listed: Set<String>) -> (files: [String], onlyFileErrors: Bool) {
        var files: [String] = []
        var onlyFileErrors = true
        for raw in stderr.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("bsdtar: ") else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { onlyFileErrors = false }
                continue
            }
            let rest = String(line.dropFirst("bsdtar: ".count))
            if rest.hasPrefix("Error exit delayed from previous errors") { continue }
            // 「bsdtar: 路径: 原因」：从左往右找第一个「: 」前面正好是列表里的路径的位置（路径里也可能有「: 」）。
            var matched: String?
            var searchStart = rest.startIndex
            while let range = rest.range(of: ": ", range: searchStart..<rest.endIndex) {
                let candidate = String(rest[rest.startIndex..<range.lowerBound])
                if listed.contains(candidate) {
                    matched = candidate
                    break
                }
                searchStart = range.upperBound
            }
            if let matched {
                if !files.contains(matched) { files.append(matched) }
            } else {
                onlyFileErrors = false
            }
        }
        return (files, onlyFileErrors)
    }

    /// 临时文件：系统给的「替换用临时目录」（和目标同一块盘，最后 move 是原子的；
    /// App 崩溃时留下的东西在临时目录里，系统会清，不会藏在「下载」里）。拿不到时退回目标文件夹里的隐藏文件。
    /// 名字不带工作区名字（避免 emoji 名字超过 255 字节）。
    static func partialURL(for target: URL) -> (file: URL, directory: URL?) {
        let folder = target.deletingLastPathComponent()
        let name = "shiduo-zip-\(UUID().uuidString).part"
        if let dir = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: folder, create: true) {
            return (dir.appendingPathComponent(name), dir)
        }
        return (folder.appendingPathComponent("." + name), nil)
    }

    /// 以前留下的临时文件：1.0 在「下载」里写的「.<名字>.zip.<8 位>.part」、这一版退回时写的「.shiduo-zip-<UUID>.part」、
    /// 临时目录里的「ShiduoWorkspaceZip-<UUID>」。只认这几种名字，而且超过一天没动过才算（正在打包的不碰）。
    static func isStaleLeftover(name: String, modified: Date, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(modified) > 24 * 3600 else { return false }
        let patterns = [
            #"^\..+\.zip\.[0-9A-F]{8}\.part$"#,
            #"^\.shiduo-zip-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.part$"#,
            #"^ShiduoWorkspaceZip-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}(\.txt)?$"#,
        ]
        return patterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    /// 打包。sources：(ZIP 里的顶层文件夹名, 来源文件夹)。target 已经是不重名的位置。
    /// job：App 退出时用来停下子进程；freeSpace：读目标磁盘剩余空间（测试可以换掉）。
    static func make(sources: [(name: String, root: URL)], target: URL,
                     isCancelled: @escaping () -> Bool = { false },
                     job: WorkspaceZipJob? = nil,
                     freeSpace: @escaping (URL) -> Int64? = WorkspaceZip.availableCapacity) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        let stopped = { isCancelled() || job?.isStopped == true }
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
        var items = 0
        for (index, source) in sources.enumerated() {
            let listing = localFiles(root: source.root, isCancelled: stopped)
            switch listing {
            case .cancelled:
                outcome.cancelled = true
                return outcome
            case .unavailable:
                // 断开了 / 没有权限：这个来源不打，别的照样打（和「取消」分开）。
                outcome.unavailableSources.append(names[index])
                continue
            case .listed(let files, let count, let skippedCloud, let unreadable):
                outcome.skippedCloud += skippedCloud
                outcome.unreadable += unreadable.map { names[index] + "/" + $0 }
                guard !files.isEmpty else { continue }
                // 临时目录里放一个指向来源的替身（符号链接），bsdtar 顺着它读，原文件不动、不拷贝。
                let link = staging.appendingPathComponent(names[index])
                do {
                    try fm.createSymbolicLink(at: link, withDestinationURL: source.root)
                } catch {
                    outcome.failed = true
                    return outcome
                }
                lines.append(contentsOf: files.map { names[index] + "/" + $0 })
                items += count
            }
        }
        if stopped() {
            outcome.cancelled = true
            return outcome
        }
        guard !lines.isEmpty else { return outcome }
        // 文件列表用 \0 分隔（名字里什么字符都不会被误解）；放在 staging 里，结束时一起删。
        let listURL = staging.appendingPathComponent(".list")
        let errorURL = staging.appendingPathComponent(".errors")
        do {
            try Data((lines.joined(separator: "\u{0}") + "\u{0}").utf8).write(to: listURL)
            try Data().write(to: errorURL)
        } catch {
            outcome.failed = true
            return outcome
        }
        let (partial, partialDir) = partialURL(for: target)
        defer {
            try? fm.removeItem(at: partial)
            if let partialDir { try? fm.removeItem(at: partialDir) }
        }
        guard let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            outcome.failed = true
            return outcome
        }
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.currentDirectoryURL = staging
        // --format zip + zip:hdrcharset=UTF-8：文件名按 UTF-8 写，并设置 UTF-8 标记（通用位 11）；
        // -n：不递归（列表里都是文件）；--null -T：从列表读名字（不当通配符）；--no-mac-metadata：不写 ._ 文件。
        process.arguments = ["-c", "--format", "zip", "--options", "zip:hdrcharset=UTF-8", "-n", "--no-mac-metadata",
                             "--null", "-T", listURL.path, "-f", partial.path]
        var environment = ProcessInfo.processInfo.environment
        // App 从访达启动时没有 LANG：不设的话 bsdtar 按 C 语言环境转换中文名会失败。
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            outcome.failed = true
            return outcome
        }
        job?.attach(process, partial: partial)
        defer { job?.detach() }
        var lastSpaceCheck = Date.distantPast
        // 等子进程结束（专用线程上等，不占 Swift 并发的协作线程池）；期间看取消和剩余空间。
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if stopped() {
                process.terminate()
                done.wait()
                outcome.cancelled = true
                return outcome
            }
            if Date().timeIntervalSince(lastSpaceCheck) > 2 {
                lastSpaceCheck = Date()
                if let free = freeSpace(partial.deletingLastPathComponent()), free < minimumFreeBytes {
                    process.terminate()
                    done.wait()
                    outcome.outOfSpace = true
                    return outcome
                }
            }
        }
        if stopped() {
            outcome.cancelled = true
            return outcome
        }
        guard fm.fileExists(atPath: partial.path) else {
            outcome.failed = true
            return outcome
        }
        if process.terminationStatus != 0 {
            // 有文件在列出来以后被删 / 改名、读不了：bsdtar 跳过它们、最后返回 1。只要别的错误没有，ZIP 照样留着。
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            let parsed = unreadableFiles(stderr: stderr, listed: Set(lines))
            guard parsed.onlyFileErrors, !parsed.files.isEmpty else {
                outcome.failed = true
                return outcome
            }
            outcome.unreadable += parsed.files
            items = max(items - parsed.files.count, 0)
        }
        // 打包期间同名文件被别人建了：换一个编号，绝不覆盖。
        let final = WorkspaceLogic.uniqueURL(for: target.lastPathComponent, in: target.deletingLastPathComponent())
        do {
            try fm.moveItem(at: partial, to: final)
        } catch {
            outcome.failed = true
            return outcome
        }
        outcome.url = final
        outcome.files = items
        return outcome
    }
}
