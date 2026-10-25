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
    /// 新位置已经有完整副本，但原位置没能删干净（有锁定或没权限的文件）：两边都保留，要用户手动处理。
    var partial: [MovedFile] = []
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
        if Demo.isOn, let fake = Demo.fakeFreeBytes(url.path) { return fake }
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
    static func logicalSize(_ url: URL) -> Int64 { MoveOutLogic.logicalSize(url) }

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
                let outcome = copyThenRemove(url, to: target, cancel: cancel) { bytes in
                    progress(MoveOutProgress(fileIndex: index, fileCount: sources.count, currentName: source.name,
                                             bytesDone: base + min(bytes, source.size), bytesTotal: total))
                }
                switch outcome {
                case .moved:
                    ok = true
                case .failed:
                    ok = false
                case .leftover:
                    // 新副本完整保留，原位置还有残留：不建替身（原位置不是空的），也不记成「搬走」。
                    done += source.size
                    result.partial.append(MovedFile(name: source.name, from: source.path, to: target.path,
                                                    size: source.size, aliasPath: nil, crossVolume: true))
                    continue
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

    enum CopyOutcome: Equatable {
        /// 拷好、核对过，原文件也删干净了。
        case moved
        /// 没搬成：原文件完整还在，目标里的半成品已清掉。
        case failed
        /// 目标里有完整副本，但原位置删到一半失败，还有残留：两边都保留。
        case leftover
    }

    /// 跨盘：先完整拷贝到目标，核对大小一致后才删除原文件；任何一步失败都保留原文件。
    /// 删原文件时先在同一目录原子改名成临时名再删：改名失败说明一个文件都没动过，才可以安全撤回拷贝；
    /// 删到一半失败时绝不删目标副本（那是唯一完整的一份），只把残留改回原名，交给用户处理。
    static func copyThenRemove(_ source: URL, to target: URL, cancel: MoveOutCancelFlag, onBytes: @escaping (Int64) -> Void) -> CopyOutcome {
        guard let expected = copyVerified(source, to: target, cancel: cancel, onBytes: onBytes) else { return .failed }
        switch MoveOutLogic.removeSource(source, expectedSize: expected, target: target) {
        case .removed: return .moved
        case .untouched: return .failed
        case .leftover: return .leftover
        }
    }

    /// 完整拷贝到目标并核对大小。成功返回字节数；失败或取消时清掉目标里的半成品、返回 nil（原文件不动）。
    static func copyVerified(_ source: URL, to target: URL, cancel: MoveOutCancelFlag, onBytes: @escaping (Int64) -> Void) -> Int64? {
        let fm = FileManager.default
        let context = CopyContext(cancel: cancel, onBytes: onBytes)
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        guard let state = copyfile_state_alloc() else { return nil }
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
            return nil
        }
        // 核对大小。
        let expected = logicalSize(source)
        let copied = logicalSize(target)
        guard expected == copied else {
            AppLog.files.error("Move out: size mismatch \(expected) vs \(copied)")
            try? fm.removeItem(at: target)
            return nil
        }
        return expected
    }

    /// 暂存架页的「移动到… / 拷贝到…」：在后台一个个处理，有进度、能取消。
    /// 移动时同一块盘直接改位置；跨盘走「拷贝、核对、删除」（和搬家一样，删原文件失败时两边都保留）。
    /// 结果里 moved 是处理成功的（拷贝时就是拷好的副本）。会阻塞，在后台线程调用。
    static func transfer(_ urls: [URL], to folder: URL, copyOnly: Bool, cancel: MoveOutCancelFlag,
                         progress: @escaping (MoveOutProgress) -> Void) -> MoveOutResult {
        let fm = FileManager.default
        var result = MoveOutResult()
        let sizes = urls.map { logicalSize($0) }
        let total = sizes.reduce(0, +)
        var done: Int64 = 0
        for (index, url) in urls.enumerated() {
            if cancel.isCancelled {
                result.cancelled = true
                break
            }
            let size = sizes[index]
            let name = url.lastPathComponent
            progress(MoveOutProgress(fileIndex: index, fileCount: urls.count, currentName: name, bytesDone: done, bytesTotal: total))
            if !copyOnly, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                result.skipped.append(name)
                done += size
                continue
            }
            let target = OrganizeEngine.uniqueURL(for: name, in: folder)
            let cross = !sameVolume(url, folder)
            let base = done
            let onBytes: (Int64) -> Void = { bytes in
                progress(MoveOutProgress(fileIndex: index, fileCount: urls.count, currentName: name,
                                         bytesDone: base + min(bytes, size), bytesTotal: total))
            }
            var ok = false
            if copyOnly {
                ok = copyVerified(url, to: target, cancel: cancel, onBytes: onBytes) != nil
            } else if cross {
                switch copyThenRemove(url, to: target, cancel: cancel, onBytes: onBytes) {
                case .moved: ok = true
                case .failed: ok = false
                case .leftover:
                    done += size
                    result.partial.append(MovedFile(name: name, from: url.path, to: target.path, size: size, aliasPath: nil, crossVolume: true))
                    continue
                }
            } else {
                do {
                    try fm.moveItem(at: url, to: target)
                    ok = true
                } catch {
                    AppLog.shelf.error("Shelf move failed: \(AppLog.describe(error), privacy: .public)")
                }
            }
            done += size
            if ok {
                result.moved.append(MovedFile(name: name, from: url.path, to: target.path, size: size, aliasPath: nil, crossVolume: cross))
            } else if cancel.isCancelled {
                result.cancelled = true
                break
            } else {
                result.failed.append(name)
            }
        }
        progress(MoveOutProgress(fileIndex: urls.count, fileCount: urls.count, currentName: "", bytesDone: done, bytesTotal: total))
        return result
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
