import Combine
import Foundation

/// 「清理记录」里的一条：拾掇移到废纸篓或搬走的一个文件。
struct CleanupRecord: Codable, Identifiable, Hashable {
    enum Action: String, Codable {
        /// 移到了废纸篓。
        case trash
        /// 搬到了别的磁盘 / 网盘 / 文件夹（Pro「大文件搬家」）。
        case moveOut
    }

    var id: UUID = UUID()
    /// 同一次操作里的文件共用一个 batchID，方便一起撤销。
    var batchID: UUID
    var date: Date
    var action: Action
    var name: String
    /// 原来的完整路径。
    var originalPath: String
    /// 现在的位置：废纸篓里的路径，或搬去的目标路径。拿不到时为 nil。
    var currentPath: String?
    var size: Int64
    /// 搬家目标的名字（「移动硬盘」「iCloud 云盘」）。
    var destinationName: String?
    /// 搬家目标的根目录（用来判断目标盘有没有连接）。
    var destinationRoot: String?
    /// 在原位置留下的替身路径。
    var aliasPath: String?
    /// 已经恢复的时间。
    var restoredAt: Date?
    /// 记录时 currentPath 那个文件的身份（inode + 大小）。旧记录没有，解码为 nil。
    /// 用来防止废纸篓清空后，同名的新文件落到同一个路径时被当成这条记录「可恢复」。
    var fileNumber: UInt64?
    var fileBytes: Int64?

    var originalFolder: String { (originalPath as NSString).deletingLastPathComponent }
}

/// 一条记录现在的状态。
enum CleanupRecordStatus: Equatable {
    /// 文件还在废纸篓 / 目标位置，可以放回去。
    case restorable
    /// 已经从拾掇里恢复了。
    case restored
    /// 废纸篓里已经找不到（多半是清空了废纸篓，或在访达里放回了）。
    case trashEmptied
    /// 搬去的磁盘 / NAS 现在没有连接。
    case destinationOffline
    /// 目标盘连着，但文件已经不在那里了。
    case missing
}

/// 一天里的清理记录。
struct CleanupDayGroup: Identifiable {
    let day: Date
    let records: [CleanupRecord]
    var id: Date { day }
}

/// 纯逻辑部分：不碰界面，单元测试直接调用。
enum CleanupHistoryLogic {
    static let maxAge: TimeInterval = 30 * 86_400

    /// 去掉 30 天以前的记录。
    static func prune(_ records: [CleanupRecord], now: Date = Date(), maxAge: TimeInterval = maxAge) -> [CleanupRecord] {
        records.filter { now.timeIntervalSince($0.date) < maxAge }
    }

    /// 文件的身份：inode 和大小（拿不到时为 nil）。
    static func identity(atPath path: String, fileManager fm: FileManager = .default) -> (number: UInt64?, bytes: Int64?) {
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return (nil, nil) }
        let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let bytes = (attrs[.size] as? NSNumber)?.int64Value
        return (number, bytes)
    }

    /// 现在 currentPath 上的文件还是不是记录时的那一个。记录里没有身份（旧记录）或现在拿不到时，当作是同一个。
    static func sameFile(_ record: CleanupRecord, identity: (number: UInt64?, bytes: Int64?)) -> Bool {
        if let expected = record.fileNumber, let actual = identity.number, expected != actual { return false }
        if let expected = record.fileBytes, let actual = identity.bytes, expected != actual { return false }
        return true
    }

    static func status(of record: CleanupRecord, exists: (String) -> Bool,
                       identity: ((String) -> (number: UInt64?, bytes: Int64?))? = nil) -> CleanupRecordStatus {
        if record.restoredAt != nil { return .restored }
        if let current = record.currentPath, exists(current),
           identity.map({ sameFile(record, identity: $0(current)) }) ?? true {
            return .restorable
        }
        switch record.action {
        case .trash:
            return .trashEmptied
        case .moveOut:
            if let root = record.destinationRoot, !exists(root) { return .destinationOffline }
            return .missing
        }
    }

    /// 放回原处用的路径：原路径空着就用原路径，否则加「 (恢复)」「 (恢复 2)」……
    static func restoreTarget(for originalPath: String, suffix: String = "恢复", exists: (String) -> Bool) -> String {
        guard exists(originalPath) else { return originalPath }
        let folder = (originalPath as NSString).deletingLastPathComponent
        let fileName = (originalPath as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension
        let base = ext.isEmpty ? fileName : (fileName as NSString).deletingPathExtension
        var n = 1
        while true {
            let tag = n == 1 ? " (\(suffix))" : " (\(suffix) \(n))"
            let name = ext.isEmpty ? base + tag : base + tag + "." + ext
            let candidate = (folder as NSString).appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// 按天分组，新的在前。
    static func groupByDay(_ records: [CleanupRecord], calendar: Calendar = .current) -> [CleanupDayGroup] {
        let groups = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            CleanupDayGroup(day: day, records: (groups[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    static func isAliasFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }

    enum RestoreError: Error, Equatable {
        case alreadyRestored
        case sourceMissing
        case moveFailed(String)
    }

    /// 把一条记录的文件放回原处，返回放回后的路径。会阻塞（跨盘时要拷贝），不要在主线程调用。
    static func restore(_ record: CleanupRecord, suffix: String = "恢复", fileManager fm: FileManager = .default) throws -> String {
        guard record.restoredAt == nil else { throw RestoreError.alreadyRestored }
        guard let current = record.currentPath, fm.fileExists(atPath: current) else { throw RestoreError.sourceMissing }
        // 路径上已经换成了别的文件（废纸篓清空后又有同名文件进来）：不能把它当成这条记录搬走。
        guard sameFile(record, identity: identity(atPath: current, fileManager: fm)) else { throw RestoreError.sourceMissing }
        // 搬家时留下的替身先挪到一边（只动替身，不会动真文件）；文件搬回来以后再删掉，搬失败就把替身放回去。
        var parkedAlias: (alias: String, parked: String)?
        if let alias = record.aliasPath, fm.fileExists(atPath: alias), isAliasFile(alias) {
            let folder = (alias as NSString).deletingLastPathComponent
            let name = "." + (alias as NSString).lastPathComponent + ".shiduo-restoring-" + UUID().uuidString
            let parked = (folder as NSString).appendingPathComponent(name)
            do {
                try fm.moveItem(atPath: alias, toPath: parked)
                parkedAlias = (alias, parked)
            } catch {
                throw RestoreError.moveFailed((error as NSError).localizedDescription)
            }
        }
        let target = restoreTarget(for: record.originalPath, suffix: suffix) { fm.fileExists(atPath: $0) }
        let folder = (target as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try fm.moveItem(atPath: current, toPath: target)
        } catch {
            if let parkedAlias, !fm.fileExists(atPath: parkedAlias.alias) {
                try? fm.moveItem(atPath: parkedAlias.parked, toPath: parkedAlias.alias)
            }
            throw RestoreError.moveFailed((error as NSError).localizedDescription)
        }
        if let parkedAlias { try? fm.removeItem(atPath: parkedAlias.parked) }
        return target
    }
}

/// 清理记录：保存在 ~/Library/Application Support/Shiduo/cleanup-history.json，只留 30 天。
@MainActor
final class CleanupHistory: ObservableObject {
    static let shared = CleanupHistory()

    @Published private(set) var records: [CleanupRecord] = []
    private let fileURL: URL

    /// 测试时可以传一个临时文件。
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = base.appendingPathComponent("Shiduo", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("cleanup-history.json")
        }
        load()
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder().decode([CleanupRecord].self, from: data) else {
            records = []
            return
        }
        let pruned = CleanupHistoryLogic.prune(decoded)
        records = pruned
        if pruned.count != decoded.count { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 记录写不进去不影响清理本身。
        }
    }

    func add(_ new: [CleanupRecord]) {
        guard !new.isEmpty else { return }
        // 新记录占用了旧记录的位置（比如废纸篓清空后同名文件又进了同一个路径）：
        // 旧的那条已经找不回了，清掉它的 currentPath，免得之后把新文件当成旧文件放回去。
        let taken = Set(new.compactMap(\.currentPath))
        var old = records
        for index in old.indices where old[index].restoredAt == nil {
            if let current = old[index].currentPath, taken.contains(current) {
                old[index].currentPath = nil
            }
        }
        records = CleanupHistoryLogic.prune(new + old)
        save()
    }

    /// 记一批移到废纸篓的文件。返回这一批的 batchID。
    @discardableResult
    func recordTrash(_ entries: [(name: String, original: String, trashed: String?, size: Int64)], date: Date = Date()) -> UUID {
        let batch = UUID()
        add(entries.map {
            var record = CleanupRecord(batchID: batch, date: date, action: .trash, name: $0.name,
                                       originalPath: $0.original, currentPath: $0.trashed, size: $0.size)
            if let trashed = $0.trashed {
                let identity = CleanupHistoryLogic.identity(atPath: trashed)
                record.fileNumber = identity.number
                record.fileBytes = identity.bytes
            }
            return record
        })
        return batch
    }

    func status(of record: CleanupRecord) -> CleanupRecordStatus {
        CleanupHistoryLogic.status(of: record,
                                   exists: { FileManager.default.fileExists(atPath: $0) },
                                   identity: { CleanupHistoryLogic.identity(atPath: $0) })
    }

    func records(inBatch batch: UUID) -> [CleanupRecord] {
        records.filter { $0.batchID == batch }
    }

    func markRestored(_ id: UUID, at path: String, date: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].restoredAt = date
        records[index].currentPath = path
        save()
    }

    /// 放回原处（在后台线程搬文件）。返回 (恢复成功的原路径, 失败的文件名)。
    func restore(_ list: [CleanupRecord]) async -> (restored: [String], failed: [String]) {
        let targets = list.filter { status(of: $0) == .restorable }
        let unavailable = list.filter { status(of: $0) != .restorable && status(of: $0) != .restored }.map(\.name)
        let suffix = String(localized: "restore.suffix", defaultValue: "恢复")
        let results: [(UUID, String?, String)] = await Task.detached(priority: .userInitiated) {
            targets.map { (record: CleanupRecord) -> (UUID, String?, String) in
                let path = try? CleanupHistoryLogic.restore(record, suffix: suffix)
                return (record.id, path, record.name)
            }
        }.value
        var restored: [String] = []
        var failed: [String] = []
        for (id, path, name) in results {
            if let path {
                // 上过色的文件夹搬回来，上色记录跟着回到原路径
                if let from = targets.first(where: { $0.id == id })?.currentPath {
                    FolderIconService.shared.movePath(from, to: path)
                }
                markRestored(id, at: path)
                restored.append(path)
            } else {
                failed.append(name)
            }
        }
        failed += unavailable
        return (restored, failed)
    }

    func removeAll() {
        records = []
        save()
    }
}
