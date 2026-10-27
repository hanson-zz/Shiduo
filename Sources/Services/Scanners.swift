import CryptoKit
import Foundation
import ImageIO
import Vision

/// 一组相关文件（重复文件、相似照片或一张清理卡片里的内容）。
struct FileGroup: Identifiable {
    let id: String
    var title: String
    var items: [FileItem]

    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

// MARK: - 重复文件

/// 先按大小分组，再比较前 64 KB 的 SHA-256，最后比较完整的 SHA-256。
@MainActor
final class DuplicateScanner: ObservableObject {
    @Published var groups: [FileGroup] = []
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var hasScanned = false
    /// 撤销了一次移到废纸篓之后：放回来的文件不会自己回到结果里，提示重新扫描。
    @Published var mayBeStale = false

    private var task: Task<Void, Never>?
    /// 每次扫描加一；旧扫描迟到的进度回调据此丢掉，不会拨动新扫描的进度条。
    private var generation = 0

    var reclaimable: Int64 {
        groups.reduce(0) { total, group in
            total + (group.items.first?.size ?? 0) * Int64(max(group.items.count - 1, 0))
        }
    }

    // 侧边栏「重复与相似」的数字：上次扫描算出的可腾出空间，存起来，下次启动不用为了这个数字重新扫一遍。
    // 超过 7 天的不再显示（文件可能早就变了）。
    private nonisolated static let cachedBytesKey = "duplicates.lastReclaimable"
    private nonisolated static let cachedDateKey = "duplicates.lastScanDate"
    private nonisolated static let cacheMaxAge: TimeInterval = 7 * 86_400

    @Published private(set) var cachedReclaimable: Int64 = DuplicateScanner.loadCachedReclaimable()

    /// 侧边栏显示的可腾出空间：这次运行扫描过就用实时结果，否则用上次扫描存下的。0 = 不显示。
    var sidebarBytes: Int64 {
        hasScanned && !isRunning ? reclaimable : cachedReclaimable
    }

    private nonisolated static func loadCachedReclaimable() -> Int64 {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: cachedDateKey) as? Date,
              Date().timeIntervalSince(date) < cacheMaxAge
        else { return 0 }
        return Int64(defaults.integer(forKey: cachedBytesKey))
    }

    private func saveCache(scanned: Bool) {
        let bytes = reclaimable
        let defaults = UserDefaults.standard
        defaults.set(Int(bytes), forKey: Self.cachedBytesKey)
        if scanned { defaults.set(Date(), forKey: Self.cachedDateKey) }
        if cachedReclaimable != bytes { cachedReclaimable = bytes }
    }

    func start(minSize: Int64 = 1_000_000) {
        task?.cancel()
        mayBeStale = false
        task = Task { await run(minSize: minSize) }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
        status = String(localized: "已停止")
    }

    func remove(paths: Set<String>) {
        remove { paths.contains($0) }
    }

    /// 去掉判断为「已经不在」的文件（文件夹被移走时，里面的文件也一起去掉）。
    func remove(where gone: (String) -> Bool) {
        groups = groups.compactMap { group in
            var g = group
            g.items.removeAll { gone($0.path) }
            return g.items.count > 1 ? g : nil
        }
        if hasScanned && !isRunning { saveCache(scanned: false) }
    }

    private func run(minSize: Int64) async {
        isRunning = true
        progress = 0
        groups = []
        status = String(localized: "正在查找候选文件…")
        let candidates = await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(minSize), P.notFolder]),
            scopes: Scopes.home, maxItems: 30_000, sortKey: "kMDItemFSSize"
        ).items.filter { !$0.isDirectory }
        if Task.isCancelled { return }
        status = String(localized: "正在比对 \(candidates.count) 个文件…")

        generation += 1
        let gen = generation
        // 后台任务不会继承取消，这里手动转过去：停止 / 重新扫描时哈希也会停下。
        let work = Task.detached(priority: .utility) { () -> [[FileItem]] in
            DuplicateScanner.findDuplicates(candidates) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.progress = value
                }
            }
        }
        let found = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if Task.isCancelled { return }

        groups = found.enumerated().map { index, items in
            let sorted = items.sorted { $0.sortDate > $1.sortDate }
            let size = sorted.first?.sizeText ?? ""
            return FileGroup(id: "dup-\(index)-\(sorted.first?.path ?? "")",
                             title: String(localized: "\(sorted.count) 份相同的文件 · 每份 \(size)"),
                             items: sorted)
        }
        status = groups.isEmpty ? String(localized: "没有发现重复文件") : String(localized: "发现 \(groups.count) 组重复文件")
        progress = 1
        isRunning = false
        hasScanned = true
        saveCache(scanned: true)
    }

    nonisolated static func sha256(of url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            // 扫描被取消：大文件不再读完。
            if Task.isCancelled { return nil }
            guard let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
            read += data.count
            if let limit, read >= limit { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func findDuplicates(_ items: [FileItem], progress: (Double) -> Void) -> [[FileItem]] {
        var bySize: [Int64: [FileItem]] = [:]
        for item in items where item.size > 0 {
            bySize[item.size, default: []].append(item)
        }
        let sizeGroups = bySize.values.filter { $0.count > 1 }
        let total = max(sizeGroups.reduce(0) { $0 + $1.count }, 1)
        var done = 0
        var result: [[FileItem]] = []

        for group in sizeGroups {
            if Task.isCancelled { break }
            let local = group.filter { FileActions.isLocal($0.url) }
            var byPartial: [String: [FileItem]] = [:]
            for item in local {
                if let hash = sha256(of: item.url, limit: 65_536) {
                    byPartial[hash, default: []].append(item)
                }
            }
            for partial in byPartial.values where partial.count > 1 {
                if Task.isCancelled { break }
                var byFull: [String: [FileItem]] = [:]
                for item in partial {
                    if let hash = sha256(of: item.url, limit: nil) {
                        byFull[hash, default: []].append(item)
                    }
                }
                result.append(contentsOf: byFull.values.filter { $0.count > 1 })
            }
            done += group.count
            progress(Double(done) / Double(total))
        }
        return result.sorted {
            ($0.first?.size ?? 0) * Int64($0.count - 1) > ($1.first?.size ?? 0) * Int64($1.count - 1)
        }
    }
}

// MARK: - 相似照片

/// 用 Vision 的图像特征向量（feature print）找看起来差不多的照片。
@MainActor
final class SimilarPhotoScanner: ObservableObject {
    @Published var groups: [FileGroup] = []
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var hasScanned = false
    /// 撤销了一次移到废纸篓之后：放回来的文件不会自己回到结果里，提示重新扫描。
    @Published var mayBeStale = false
    /// 距离阈值，越小越严格。
    @Published var threshold: Double = 0.45

    private var task: Task<Void, Never>?
    /// 每次扫描加一；旧扫描迟到的进度回调据此丢掉，不会拨动新扫描的进度条。
    private var generation = 0

    func start(limit: Int = 800) {
        task?.cancel()
        mayBeStale = false
        task = Task { await run(limit: limit) }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
        status = String(localized: "已停止")
    }

    func remove(paths: Set<String>) {
        remove { paths.contains($0) }
    }

    /// 去掉判断为「已经不在」的文件（文件夹被移走时，里面的文件也一起去掉）。
    func remove(where gone: (String) -> Bool) {
        groups = groups.compactMap { group in
            var g = group
            g.items.removeAll { gone($0.path) }
            return g.items.count > 1 ? g : nil
        }
    }

    private func run(limit: Int) async {
        isRunning = true
        progress = 0
        groups = []
        status = String(localized: "正在读取最近的照片…")
        let images = await SpotlightSearch.run(
            predicate: FileCategory.images.predicate(), scopes: Scopes.home,
            maxItems: limit, sortKey: "kMDItemFSContentChangeDate"
        ).items.filter { $0.size > 20_000 }
        if Task.isCancelled { return }
        status = String(localized: "正在分析 \(images.count) 张照片…")
        let maxDistance = Float(threshold)

        generation += 1
        let gen = generation
        // 后台任务不会继承取消，这里手动转过去：停止 / 重新扫描时 Vision 分析也会停下。
        let work = Task.detached(priority: .utility) { () -> [[FileItem]] in
            SimilarPhotoScanner.cluster(images, maxDistance: maxDistance) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.progress = value
                }
            }
        }
        let clusters = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if Task.isCancelled { return }

        let pairs = SimilarPhotoScanner.namePairs(images.filter { FileActions.isLocal($0.url) })
        let merged = SimilarPhotoScanner.merge(clusters + pairs)
        groups = merged.enumerated().map { index, items in
            let sorted = items.sorted { $0.sortDate > $1.sortDate }
            return FileGroup(id: "sim-\(index)-\(sorted.first?.path ?? "")",
                             title: SimilarPhotoScanner.title(for: sorted),
                             items: sorted)
        }
        status = groups.isEmpty ? String(localized: "没有发现相似的照片") : String(localized: "发现 \(groups.count) 组相似照片")
        progress = 1
        isRunning = false
        hasScanned = true
    }

    /// 同一文件夹里去掉扩展名和“(edited)”“副本”“ (1)”之后同名的照片：HEIC/JPEG 成对、编辑版。
    nonisolated static func baseKey(_ item: FileItem) -> String {
        var name = (item.name as NSString).deletingPathExtension.lowercased()
        let suffixes = [" (edited)", "(edited)", "-edited", "_edited", " edited", "(已编辑)", " 已编辑", " 副本", "-副本", " copy"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                changed = true
            }
            if let range = name.range(of: " ?\\(\\d+\\)$", options: .regularExpression) {
                name.removeSubrange(range)
                changed = true
            }
        }
        return item.url.deletingLastPathComponent().path + "/" + name
    }

    nonisolated static func namePairs(_ items: [FileItem]) -> [[FileItem]] {
        Dictionary(grouping: items, by: baseKey).values.filter { $0.count > 1 }.map { Array($0) }
    }

    /// 有共同文件的组合并成一组。
    nonisolated static func merge(_ groups: [[FileItem]]) -> [[FileItem]] {
        var result: [[FileItem]] = []
        for group in groups {
            var combined = group
            var paths = Set(group.map(\.path))
            result.removeAll { existing in
                guard existing.contains(where: { paths.contains($0.path) }) else { return false }
                for item in existing where !paths.contains(item.path) {
                    combined.append(item)
                    paths.insert(item.path)
                }
                return true
            }
            result.append(combined)
        }
        return result.sorted { $0.count > $1.count }
    }

    nonisolated static func title(for items: [FileItem]) -> String {
        let exts = Set(items.map(\.ext))
        let keys = Set(items.map(baseKey))
        if exts.contains("heic") && (exts.contains("jpg") || exts.contains("jpeg")) && keys.count == 1 {
            return String(localized: "HEIC 和 JPEG 成对")
        }
        if keys.count == 1 { return String(localized: "原图和编辑版") }
        return String(localized: "\(items.count) 张相似的照片")
    }

    nonisolated static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    nonisolated static func cluster(_ items: [FileItem], maxDistance: Float, progress: (Double) -> Void) -> [[FileItem]] {
        var prints: [(FileItem, VNFeaturePrintObservation)] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled { return [] }
            if FileActions.isLocal(item.url), let fp = featurePrint(item.url) {
                prints.append((item, fp))
            }
            progress(Double(index + 1) / Double(max(items.count, 1)) * 0.8)
        }

        // 并查集
        var parent = Array(0..<prints.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for i in 0..<prints.count {
            if Task.isCancelled { return [] }
            for j in (i + 1)..<prints.count {
                var distance: Float = 0
                if (try? prints[i].1.computeDistance(&distance, to: prints[j].1)) != nil, distance < maxDistance {
                    let a = find(i), b = find(j)
                    if a != b { parent[a] = b }
                }
            }
        }
        var buckets: [Int: [FileItem]] = [:]
        for i in 0..<prints.count {
            buckets[find(i), default: []].append(prints[i].0)
        }
        progress(1)
        return buckets.values.filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }
}

// MARK: - 清理建议

enum CleanupKind: String, CaseIterable, Identifiable {
    case installers
    case otherInstallers
    case screenRecordings
    case oldDownloads
    case oldScreenshots
    case bigOldVideos
    case bigFiles
    case unusedApps
    case chatFiles

    var id: String { rawValue }

    /// 放心清：确认用过、能重新下载的，默认勾选；其余你来决定，默认不勾。
    var group: CleanupGroup {
        switch self {
        case .installers: return .safe
        default: return .review
        }
    }

    var title: String {
        switch self {
        case .installers: return String(localized: "已安装应用的安装包")
        case .otherInstallers: return String(localized: "其他旧安装包")
        case .screenRecordings: return String(localized: "旧录屏")
        case .oldDownloads: return String(localized: "被遗忘的下载")
        case .oldScreenshots: return String(localized: "旧截图")
        case .bigOldVideos: return String(localized: "很久没看的大视频")
        case .bigFiles: return String(localized: "很久没打开的大文件")
        case .unusedApps: return String(localized: "不常用的应用")
        case .chatFiles: return String(localized: "微信 / QQ 大文件")
        }
    }

    /// 为什么建议清：显示在卡片和审阅页上。
    var detail: String {
        switch self {
        case .installers: return String(localized: "对应的应用已经装在“应用程序”里，安装包用完了；要重装可以再下载")
        case .otherInstallers: return String(localized: "“下载”和桌面上超过 7 天的 .dmg / .pkg，没找到对应的已装应用，可能还没装")
        case .screenRecordings: return String(localized: "30 天以前录的屏幕录像，通常只用一次")
        case .oldDownloads: return String(localized: "“下载”里放了 90 天以上、之后再没打开过的文件")
        case .oldScreenshots: return String(localized: "30 天以前拍的截图")
        case .bigOldVideos: return String(localized: "超过 200 MB、90 天没打开的视频")
        case .bigFiles: return String(localized: "超过 1 GB、90 天没打开的文件（不含视频和应用）")
        case .unusedApps: return String(localized: "“应用程序”里半年以上没打开过的第三方应用")
        case .chatFiles: return String(localized: "聊天里收到的 20 MB 以上的文件和视频，删掉后聊天里就打不开了")
        }
    }

    var symbol: String {
        switch self {
        case .installers: return "shippingbox"
        case .otherInstallers: return "shippingbox.circle"
        case .screenRecordings: return "record.circle"
        case .oldDownloads: return "tray.and.arrow.down"
        case .oldScreenshots: return "camera.viewfinder"
        case .bigOldVideos: return "film.stack"
        case .bigFiles: return "externaldrive"
        case .unusedApps: return "app.dashed"
        case .chatFiles: return "message.fill"
        }
    }
}

struct CleanupCard: Identifiable {
    let kind: CleanupKind
    var items: [FileItem]
    var id: String { kind.rawValue }
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

@MainActor
final class CleanupScanner: ObservableObject {
    @Published var cards: [CleanupCard] = []
    @Published var isRunning = false
    @Published var hasScanned = false

    var totalBytes: Int64 { cards.reduce(0) { $0 + $1.bytes } }

    func remove(paths: Set<String>) {
        remove { paths.contains($0) }
    }

    func remove(where gone: (String) -> Bool) {
        cards = cards.map { card in
            var c = card
            c.items.removeAll { gone($0.path) }
            return c
        }
    }

    func scan() async {
        isRunning = true
        defer {
            isRunning = false
            hasScanned = true
        }
        let now = Date()
        func daysAgo(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now }
        let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

        // 安装包：先看对应的应用装了没有。装了 → 放心清；没装、放了 7 天以上 → 你来决定。
        let installerHits = await SpotlightSearch.run(
            predicate: P.any(installerExts.map { P.nameLike("*.\($0)") }),
            scopes: [Folders.downloads, Folders.desktop], maxItems: 1000, sortKey: "kMDItemFSSize"
        ).items
        let installedAppNames = await SpotlightSearch.run(
            predicate: P.type("com.apple.application-bundle"), scopes: Scopes.apps,
            maxItems: 3000, sortKey: "kMDItemFSName", ascending: true
        ).items.map(\.name)
        var installedInstallers: [FileItem] = []
        var otherInstallers: [FileItem] = []
        for item in installerHits {
            let added = item.added ?? item.created ?? item.modified ?? now
            if SmartCleanupLogic.installedApp(forInstaller: item.name, appNames: installedAppNames) != nil {
                if added < daysAgo(1) { installedInstallers.append(item) }
            } else if added < daysAgo(7) {
                otherInstallers.append(item)
            }
        }

        // 被遗忘的下载（只看“下载”文件夹第一层，90 天）
        let downloadsRoot = URL(fileURLWithPath: Folders.downloads).standardizedFileURL.path
        let oldDownloads = await SpotlightSearch.run(
            predicate: P.all([P.everything, P.notFolder]), scopes: [Folders.downloads],
            maxItems: 3000, sortKey: "kMDItemFSSize"
        ).items.filter { item in
            guard item.url.deletingLastPathComponent().standardizedFileURL.path == downloadsRoot,
                  !installerExts.contains(item.ext)
            else { return false }
            let added = item.added ?? item.created ?? item.modified ?? now
            let used = item.lastUsed ?? .distantPast
            return added < daysAgo(90) && used < daysAgo(90)
        }

        // 旧截图
        let oldScreenshots = await SpotlightSearch.run(
            predicate: P.screenshot, scopes: Scopes.home, maxItems: 5000, sortKey: "kMDItemFSCreationDate"
        ).items.filter { $0.isScreenshot && ($0.created ?? $0.modified ?? now) < daysAgo(30) }

        // 旧录屏（单独一张，不再混在大视频里）
        let videos = await SpotlightSearch.run(
            predicate: FileCategory.videos.predicate(), scopes: Scopes.home, maxItems: 5000, sortKey: "kMDItemFSSize"
        ).items
        let recordings = videos.filter {
            SmartCleanupLogic.isScreenRecording(name: $0.name) && ($0.created ?? $0.modified ?? now) < daysAgo(30)
        }

        // 很久没看的大视频
        let bigVideos = videos.filter {
            $0.size >= 200_000_000 && ($0.lastUsed ?? $0.modified ?? now) < daysAgo(90)
        }

        // 很久没打开的大文件（1 GB 以上，不含视频、应用、安装包和资源库里的东西）
        let library = Folders.path("Library") + "/"
        let bigFiles = await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(1_000_000_000), P.notFolder]), scopes: Scopes.home,
            maxItems: 1000, sortKey: "kMDItemFSSize"
        ).items.filter { item in
            item.category != .videos && item.ext != "app" && !installerExts.contains(item.ext)
                && !item.path.hasPrefix(library)
                && (item.lastUsed ?? item.modified ?? now) < daysAgo(90)
        }

        // 不常用的应用（只看 /Applications 第一层的第三方应用）
        let ownID = Bundle.main.bundleIdentifier ?? ""
        var apps = await SpotlightSearch.run(
            predicate: P.type("com.apple.application-bundle"), scopes: ["/Applications"],
            maxItems: 1000, sortKey: "kMDItemFSName", ascending: true
        ).items.filter { item in
            guard item.url.deletingLastPathComponent().path == "/Applications" else { return false }
            let id = item.bundleID ?? ""
            guard !id.hasPrefix("com.apple."), id != ownID else { return false }
            return (item.lastUsed ?? .distantPast) < daysAgo(180)
        }
        let appList = apps
        apps = await Task.detached(priority: .utility) { () -> [FileItem] in
            appList.map { app in
                var a = app
                if a.size == 0 { a.size = FileActions.directorySize(a.url) }
                return a
            }
        }.value

        let local: ([FileItem]) -> [FileItem] = { $0.filter { FileActions.isLocal($0.url) } }
        // 顺序就是归属优先级：一个文件只出现在第一张认领它的卡片里，总量不会重复算。
        let ordered: [(CleanupKind, [FileItem])] = [
            (.installers, local(installedInstallers)),
            (.otherInstallers, local(otherInstallers)),
            (.screenRecordings, local(recordings)),
            (.bigOldVideos, local(bigVideos)),
            (.oldScreenshots, local(oldScreenshots)),
            (.oldDownloads, local(oldDownloads)),
            (.bigFiles, local(bigFiles)),
            (.unusedApps, apps.sorted { $0.size > $1.size }),
        ]
        let kept = SmartCleanupLogic.dedupe(ordered.map { ($0.0, $0.1.map(\.path)) })
        cards = zip(ordered, kept).map { pair, keep in
            let paths = Set(keep.1)
            return CleanupCard(kind: pair.0, items: pair.1.filter { paths.contains($0.path) })
        }
        updateChatCard()
    }

    /// 微信 / QQ 大文件：只在扫描过聊天文件后出现。
    func updateChatCard() {
        let chat = ChatFilesStore.shared
        cards.removeAll { $0.kind == .chatFiles }
        guard chat.hasScanned else { return }
        let big = chat.allFiles.filter { $0.size >= 20_000_000 }.sorted { $0.size > $1.size }
        cards.append(CleanupCard(kind: .chatFiles, items: big))
    }
}
