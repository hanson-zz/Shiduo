import AppKit
import Darwin
import Foundation

// MARK: - 目标位置

/// 大文件可以搬去的地方：移动硬盘、NAS、iCloud 云盘、网盘同步文件夹，或自己选的文件夹。
struct MoveDestination: Identifiable, Hashable {
    enum Kind: String {
        case external
        case network
        case iCloud
        case cloudSync
        case custom
    }

    let kind: Kind
    let name: String
    let path: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var symbol: String {
        switch kind {
        case .external: return "externaldrive.fill"
        case .network: return "server.rack"
        case .iCloud: return "icloud.fill"
        case .cloudSync: return "cloud.fill"
        case .custom: return "folder.fill"
        }
    }

    var kindText: String {
        switch kind {
        case .external: return String(localized: "外接磁盘")
        case .network: return String(localized: "网络磁盘 / NAS")
        case .iCloud: return String(localized: "iCloud 云盘")
        case .cloudSync: return String(localized: "网盘同步文件夹")
        case .custom: return String(localized: "文件夹")
        }
    }

    /// 目标所在磁盘的可用空间。
    var availableBytes: Int64 { MoveOutEngine.availableBytes(at: url) }

    /// iCloud 和网盘同步文件夹都在这台 Mac 的磁盘上：搬进去要等同步完、设为「仅在云端」才真正腾出空间。
    var isSyncFolder: Bool { kind == .iCloud || kind == .cloudSync }
}

enum MoveDestinations {
    /// 找出现在能用的目标：外接磁盘（复用 VolumeMonitor 的列表）、NAS、iCloud 云盘、各家网盘同步文件夹。
    static func detect(volumes: [ExternalVolume]) -> [MoveDestination] {
        let fm = FileManager.default
        var result: [MoveDestination] = []
        var seen = Set<String>()
        func add(_ d: MoveDestination) {
            guard !seen.contains(d.path) else { return }
            seen.insert(d.path)
            result.append(d)
        }

        // 外接磁盘和网络磁盘（NAS 的 SMB / AFP 卷 volumeIsLocal 为 false）。
        var volumeURLs = volumes.map(\.url)
        let netKeys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeLocalizedNameKey]
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: netKeys, options: [.skipHiddenVolumes]) ?? [] {
            let v = try? url.resourceValues(forKeys: Set(netKeys))
            if v?.volumeIsLocal == false, !volumeURLs.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                volumeURLs.append(url)
            }
        }
        for url in volumeURLs {
            let v = try? url.resourceValues(forKeys: Set(netKeys))
            guard fm.isWritableFile(atPath: url.path) else { continue }
            let name = volumes.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }?.name
                ?? v?.volumeLocalizedName ?? url.lastPathComponent
            add(MoveDestination(kind: v?.volumeIsLocal == false ? .network : .external, name: name, path: url.standardizedFileURL.path))
        }

        let home = fm.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            add(MoveDestination(kind: .iCloud, name: String(localized: "iCloud 云盘"), path: iCloud.path))
        }

        // macOS 12 以后的网盘（Dropbox、Google 云端硬盘、OneDrive、百度网盘……）都在 ~/Library/CloudStorage 下。
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            add(MoveDestination(kind: .cloudSync, name: cloudName(url.lastPathComponent), path: url.path))
        }
        // 老版本网盘放在个人文件夹里的同步目录。
        let homeEntries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        let prefixes = ["BaiduNetdisk", "百度网盘", "Dropbox", "Google Drive", "OneDrive", "坚果云", "Nutstore"]
        for name in homeEntries.sorted() where prefixes.contains(where: { name.hasPrefix($0) }) {
            var isDir: ObjCBool = false
            let path = home.appendingPathComponent(name).path
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            add(MoveDestination(kind: .cloudSync, name: cloudName(name), path: path))
        }
        return result
    }

    /// 「GoogleDrive-me@gmail.com」→「Google 云端硬盘（me@gmail.com）」。
    static func cloudName(_ folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = parts.first ?? folder
        let account = parts.count > 1 ? parts[1] : nil
        let lower = provider.lowercased()
        let pretty: String
        if lower.hasPrefix("googledrive") || lower.hasPrefix("google drive") {
            pretty = String(localized: "Google 云端硬盘")
        } else if lower.hasPrefix("baidunetdisk") || provider.hasPrefix("百度网盘") {
            pretty = String(localized: "百度网盘")
        } else if lower.hasPrefix("onedrive") {
            pretty = "OneDrive"
        } else if lower.hasPrefix("dropbox") {
            pretty = "Dropbox"
        } else if lower.hasPrefix("nutstore") || provider.hasPrefix("坚果云") {
            pretty = String(localized: "坚果云")
        } else {
            pretty = provider
        }
        if let account, !account.isEmpty { return "\(pretty)（\(account)）" }
        return pretty
    }
}

// MARK: - 搬家（不在主线程）

/// 线程安全的取消标记。
final class MoveOutCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}

struct MoveOutSource: Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let isDirectory: Bool
}

struct MoveOutOptions: Sendable {
    let destinationRoot: String
    let destinationName: String
    let keepAlias: Bool
    let keepStructure: Bool
    /// 「拾掇搬家」文件夹的名字。
    let folderName: String
}

struct MovedFile: Hashable, Sendable {
    let name: String
    let from: String
    let to: String
    let size: Int64
    let aliasPath: String?
    let crossVolume: Bool
}

struct MoveOutResult: Sendable {
    var moved: [MovedFile] = []
    var skipped: [String] = []
    var failed: [String] = []
    /// 搬成了，但原位置的替身没建成（原位置现在是空的）。
    var aliasFailed: [String] = []
    var cancelled = false
    /// 源磁盘上腾出的空间（只算跨盘搬走的）。
    var freedBytes: Int64 { moved.filter(\.crossVolume).reduce(0) { $0 + $1.size } }
    var movedBytes: Int64 { moved.reduce(0) { $0 + $1.size } }
}

struct MoveOutProgress: Sendable {
    var fileIndex: Int
    var fileCount: Int
    var currentName: String
    var bytesDone: Int64
    var bytesTotal: Int64
}

/// copyfile 回调用的上下文。
private final class CopyContext {
    let cancel: MoveOutCancelFlag
    let onBytes: (Int64) -> Void
    var last = Date.distantPast
    init(cancel: MoveOutCancelFlag, onBytes: @escaping (Int64) -> Void) {
        self.cancel = cancel
        self.onBytes = onBytes
    }
}

/// copyfile 的进度回调：报告已拷贝的字节数；取消时返回 COPYFILE_QUIT。
private let copyProgressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if context.cancel.isCancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
        let now = Date()
        if now.timeIntervalSince(context.last) > 0.1 {
            context.last = now
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            context.onBytes(Int64(copied))
        }
    }
    return COPYFILE_CONTINUE
}

enum MoveOutEngine {
    static func availableBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
              let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject else {
            return false
        }
        return va.isEqual(vb)
    }

    /// 文件（或文件夹里所有文件）的字节数，用来核对拷贝是否完整。
    static func logicalSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory != true { return Int64(values?.fileSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in e {
                let v = try? file.resourceValues(forKeys: keys)
                if v?.isDirectory != true, v?.isSymbolicLink != true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// 目标文件夹：<目标>/拾掇搬家/<原来所在文件夹的名字>/，或直接放在目标根目录。
    static func folder(for source: URL, options: MoveOutOptions) -> URL {
        let root = URL(fileURLWithPath: options.destinationRoot, isDirectory: true)
        guard options.keepStructure else { return root }
        let parent = source.deletingLastPathComponent().lastPathComponent
        return root.appendingPathComponent(options.folderName, isDirectory: true)
            .appendingPathComponent(parent.isEmpty ? "Root" : parent, isDirectory: true)
    }

    /// 需要的空间：只算跨盘的（同一块盘只是改个位置）。
    static func requiredBytes(_ sources: [MoveOutSource], destination: URL) -> Int64 {
        sources.filter { !sameVolume(URL(fileURLWithPath: $0.path), destination) }.reduce(0) { $0 + $1.size }
    }

    /// 一个一个搬。会阻塞，在后台线程调用。
    static func run(_ sources: [MoveOutSource], options: MoveOutOptions, cancel: MoveOutCancelFlag,
                    progress: @escaping (MoveOutProgress) -> Void) -> MoveOutResult {
        let fm = FileManager.default
        var result = MoveOutResult()
        let total = sources.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        let destinationRoot = URL(fileURLWithPath: options.destinationRoot, isDirectory: true)

        for (index, source) in sources.enumerated() {
            if cancel.isCancelled {
                result.cancelled = true
                break
            }
            let url = URL(fileURLWithPath: source.path)
            progress(MoveOutProgress(fileIndex: index, fileCount: sources.count, currentName: source.name,
                                     bytesDone: done, bytesTotal: total))
            // 已经是替身、只在 iCloud 云端、或者本来就在目标里的，跳过。
            if isAlias(url) || !FileActions.isLocal(url) || source.path.hasPrefix(destinationRoot.path + "/") {
                result.skipped.append(source.name)
                done += source.size
                continue
            }
            let destFolder = folder(for: url, options: options)
            do {
                try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
            } catch {
                AppLog.files.error("Move out: cannot create folder: \(AppLog.describe(error), privacy: .public)")
                result.failed.append(source.name)
                done += source.size
                continue
            }
            let target = OrganizeEngine.uniqueURL(for: url.lastPathComponent, in: destFolder)
            let cross = !sameVolume(url, destinationRoot)
            let base = done
            let ok: Bool
            if cross {
                ok = copyThenRemove(url, to: target, cancel: cancel) { bytes in
                    progress(MoveOutProgress(fileIndex: index, fileCount: sources.count, currentName: source.name,
                                             bytesDone: base + min(bytes, source.size), bytesTotal: total))
                }
            } else {
                do {
                    try fm.moveItem(at: url, to: target)
                    ok = true
                } catch {
                    AppLog.files.error("Move out (same volume) failed: \(AppLog.describe(error), privacy: .public)")
                    ok = false
                }
            }
            done += source.size
            guard ok else {
                if cancel.isCancelled {
                    result.cancelled = true
                    break
                }
                result.failed.append(source.name)
                continue
            }
            var aliasPath: String?
            if options.keepAlias {
                do {
                    let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try URL.writeBookmarkData(data, to: url)
                    aliasPath = url.path
                } catch {
                    AppLog.files.error("Move out: alias failed: \(AppLog.describe(error), privacy: .public)")
                    result.aliasFailed.append(source.name)
                }
            }
            result.moved.append(MovedFile(name: source.name, from: source.path, to: target.path,
                                          size: source.size, aliasPath: aliasPath, crossVolume: cross))
        }
        progress(MoveOutProgress(fileIndex: sources.count, fileCount: sources.count, currentName: "",
                                 bytesDone: done, bytesTotal: total))
        return result
    }

    /// 跨盘：先完整拷贝到目标，核对大小一致后才删除原文件；任何一步失败都保留原文件。
    static func copyThenRemove(_ source: URL, to target: URL, cancel: MoveOutCancelFlag, onBytes: @escaping (Int64) -> Void) -> Bool {
        let fm = FileManager.default
        let context = CopyContext(cancel: cancel, onBytes: onBytes)
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        guard let state = copyfile_state_alloc() else { return false }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), UnsafeRawPointer(unmanaged.toOpaque()))

        var flags = copyfile_flags_t(COPYFILE_ALL) | copyfile_flags_t(COPYFILE_EXCL) | copyfile_flags_t(COPYFILE_NOFOLLOW)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
            flags |= copyfile_flags_t(COPYFILE_RECURSIVE)
        }
        let status = copyfile(source.path, target.path, state, flags)
        guard status == 0, !cancel.isCancelled else {
            // 没拷完（或被取消）：删掉目标里的半成品，原文件不动。
            try? fm.removeItem(at: target)
            return false
        }
        // 核对大小。
        let expected = logicalSize(source)
        let copied = logicalSize(target)
        guard expected == copied else {
            AppLog.files.error("Move out: size mismatch \(expected) vs \(copied)")
            try? fm.removeItem(at: target)
            return false
        }
        do {
            try fm.removeItem(at: source)
            return true
        } catch {
            // 删不掉原文件（权限等）：撤回拷贝，免得出现两份。
            AppLog.files.error("Move out: cannot remove source: \(AppLog.describe(error), privacy: .public)")
            try? fm.removeItem(at: target)
            return false
        }
    }
}

// MARK: - 记住选择

enum MoveOutSettings {
    private static let lastKey = "moveOut.lastDestination"
    private static let customKey = "moveOut.customFolders"
    private static let aliasKey = "moveOut.keepAlias"
    private static let structureKey = "moveOut.keepStructure"

    static var lastDestination: String? {
        get { UserDefaults.standard.string(forKey: lastKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }

    /// 用「选择文件夹…」选过的文件夹（最多记 5 个）。
    static var customFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: customKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(5)), forKey: customKey) }
    }

    static var keepAlias: Bool {
        get { UserDefaults.standard.object(forKey: aliasKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: aliasKey) }
    }

    static var keepStructure: Bool {
        get { UserDefaults.standard.object(forKey: structureKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: structureKey) }
    }
}
