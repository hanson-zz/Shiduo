import XCTest

/// 工作区（Pro）：模型、存取（带版本号）、迁移、离线判定、统计、删除不碰原文件、打包 ZIP 不覆盖同名。
final class WorkspaceLogicTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("shiduo-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - 工具

    @discardableResult
    private func write(_ text: String, _ rel: String, in root: URL, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func folder(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 一个文件夹里所有东西的「指纹」：相对路径 → 大小 + 修改时间 + 内容。用来证明原文件一点没变。
    private func fingerprint(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]) else { return [:] }
        let prefix = root.standardizedFileURL.path + "/"
        while let url = e.nextObject() as? URL {
            let rel = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            if v?.isDirectory == true {
                out[rel] = "dir"
            } else {
                let data = (try? Data(contentsOf: url)) ?? Data()
                out[rel] = "\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(data.base64EncodedString())"
            }
        }
        return out
    }

    private func volume(_ mount: String, uuid: String?, name: String = "闪迪", capacity: Int64 = 1_000, external: Bool = true) -> BackupVolumeInfo {
        BackupVolumeInfo(mountPath: mount, uuid: uuid, name: name, capacity: capacity, isExternal: external)
    }

    // MARK: - 模型 / 持久化

    func testRoundTripKeepsEverything() throws {
        var stats = WorkspaceSourceStats()
        stats.fileCount = 12
        stats.folderCount = 3
        stats.bytes = 4_096
        stats.images = 5
        stats.documents = 4
        stats.videos = 1
        stats.others = 2
        stats.cloudOnly = 1
        stats.lastModified = Date(timeIntervalSince1970: 1_700_000_000)
        stats.scannedAt = Date(timeIntervalSince1970: 1_700_000_100)
        stats.recent = [WorkspaceFileEntry(path: "/a/b.png", name: "b.png", modified: Date(timeIntervalSince1970: 1_700_000_000),
                                           bytes: 10, kind: .image, cloudOnly: false)]
        let source = WorkspaceSource(bookmark: Data([1, 2, 3]), path: "/Volumes/闪迪/素材", kind: .external,
                                     volumeUUID: "ABC", volumeName: "闪迪", volumeCapacity: 1_000, relativePath: "素材",
                                     added: Date(timeIntervalSince1970: 1_600_000_000), stats: stats)
        let workspace = Workspace(name: "默认工作区", colorIndex: 2, symbol: "film", sources: [source],
                                  created: Date(timeIntervalSince1970: 1_600_000_000))
        let file = WorkspacesFile(workspaces: [workspace], seededDefault: true)
        let decoded = WorkspaceCodec.decode(WorkspaceCodec.encode(file))
        XCTAssertEqual(decoded.version, WorkspacesFile.currentVersion)
        XCTAssertEqual(decoded.workspaces, [workspace])
        XCTAssertTrue(decoded.seededDefault)
    }

    func testFirstLaunchSeedsOneEmptyDefaultWorkspace() {
        let file = WorkspaceCodec.decode(nil)
        XCTAssertEqual(file.workspaces.count, 1)
        XCTAssertEqual(file.workspaces.first?.name, WorkspaceLogic.defaultName)
        XCTAssertEqual(file.workspaces.first?.sources, [])
        XCTAssertTrue(file.seededDefault)
        XCTAssertEqual(file.version, WorkspacesFile.currentVersion)
    }

    func testDeletedAllWorkspacesStaysEmpty() {
        let file = WorkspaceCodec.decode(WorkspaceCodec.encode(WorkspacesFile(workspaces: [], seededDefault: true)))
        XCTAssertTrue(file.workspaces.isEmpty, "用户删光了就不再自动建默认工作区")
    }

    func testLegacyAndFutureFilesDecodeLeniently() throws {
        // 旧格式：没有 version / seededDefault；以后的格式：多了不认识的字段、不认识的位置类型。
        let json = """
        {
          "workspaces": [
            {"id": "11111111-1111-1111-1111-111111111111", "name": "品牌", "futureField": 42,
             "sources": [
               {"path": "/Users/me/Desktop/设计稿", "kind": "nas", "extra": true},
               {"path": "relative/path"},
               {"kind": "local"}
             ]},
            {"id": "22222222-2222-2222-2222-222222222222"},
            {"id": "11111111-1111-1111-1111-111111111111", "name": "重复的 id"},
            {"name": "   ", "colorIndex": 99}
          ],
          "somethingNew": {"a": 1}
        }
        """
        let file = WorkspaceCodec.decode(Data(json.utf8))
        XCTAssertEqual(file.version, WorkspacesFile.currentVersion)
        XCTAssertTrue(file.seededDefault, "旧数据里已经有工作区：不再额外建默认工作区")
        XCTAssertEqual(file.workspaces.count, 2, "没名字的那个丢掉，重复 id 只留第一个")
        let first = try XCTUnwrap(file.workspaces.first)
        XCTAssertEqual(first.name, "品牌")
        XCTAssertEqual(first.symbol, WorkspaceLogic.defaultSymbol)
        XCTAssertEqual(first.colorIndex, WorkspaceLogic.defaultColorIndex)
        XCTAssertEqual(first.sources.count, 1, "相对路径、没有路径的来源丢掉")
        XCTAssertEqual(first.sources.first?.kind, .local, "认不出的位置类型按本地")
        XCTAssertEqual(file.workspaces[1].name, WorkspaceLogic.defaultName, "空白名字换成默认名")
    }

    func testCorruptDataDoesNotCrash() {
        let file = WorkspaceCodec.decode(Data("not json".utf8))
        XCTAssertEqual(file.workspaces.count, 1)
    }

    func testSanitizeRelativePathOnDecode() throws {
        let source = WorkspaceSource(path: "/Volumes/A/x", kind: .external, volumeUUID: "U", relativePath: "../../etc")
        let file = WorkspacesFile(workspaces: [Workspace(name: "W", sources: [source])], seededDefault: true)
        let decoded = WorkspaceCodec.decode(WorkspaceCodec.encode(file))
        XCTAssertNil(decoded.workspaces.first?.sources.first?.relativePath, "跳出硬盘根目录的相对路径不要")
    }

    // MARK: - 名字 / 排序

    func testNames() {
        XCTAssertNil(WorkspaceLogic.sanitizedName("   \n "))
        XCTAssertEqual(WorkspaceLogic.sanitizedName("  品牌\n改版 "), "品牌 改版")
        XCTAssertEqual(WorkspaceLogic.sanitizedName(String(repeating: "长", count: 100))?.count, WorkspaceLogic.maxNameLength)
        let base = String(localized: "新工作区")
        XCTAssertEqual(WorkspaceLogic.newName(existing: []), base)
        XCTAssertEqual(WorkspaceLogic.newName(existing: [base, "\(base) 2"]), "\(base) 3")
    }

    func testMoveLikeSwiftUI() {
        let list = ["a", "b", "c", "d"]
        XCTAssertEqual(WorkspaceLogic.move(list, from: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"])
        XCTAssertEqual(WorkspaceLogic.move(list, from: IndexSet(integer: 3), to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(WorkspaceLogic.move(list, from: IndexSet([0, 2]), to: 4), ["b", "d", "a", "c"])
        XCTAssertEqual(WorkspaceLogic.move(list, from: IndexSet(integer: 9), to: 0), list)
    }

    // MARK: - 来源

    func testKindFromPath() {
        let home = "/Users/me"
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Users/me/Desktop/设计稿", home: home, isExternalVolume: false), .desktop)
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Users/me/Downloads/参考图", home: home, isExternalVolume: false), .downloads)
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Users/me/Documents", home: home, isExternalVolume: false), .documents)
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/客户", home: home, isExternalVolume: false), .iCloud)
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Users/me/Projects", home: home, isExternalVolume: false), .local)
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Volumes/闪迪/素材", home: home, isExternalVolume: true), .external)
        XCTAssertEqual(WorkspaceLogic.kind(forPath: "/Users/me/Desktopper", home: home, isExternalVolume: false), .local)
    }

    func testMakeSourceRecordsVolumeForExternal() throws {
        let dir = try folder("盘/素材/第一天")
        let mount = base.appendingPathComponent("盘").path
        let source = WorkspaceLogic.makeSource(url: dir, volume: volume(mount, uuid: "UUID-1"))
        XCTAssertEqual(source.kind, .external)
        XCTAssertEqual(source.volumeUUID, "UUID-1")
        XCTAssertEqual(source.relativePath, "素材/第一天")
        XCTAssertNotNil(source.bookmark)
        let local = WorkspaceLogic.makeSource(url: dir, volume: volume("/", uuid: "ROOT", external: false))
        XCTAssertNil(local.volumeUUID, "内置盘不记卷")
        XCTAssertFalse(local.isOnExternalVolume)
    }

    func testAddProblems() {
        let existing = [WorkspaceSource(path: "/Users/me/Desktop/设计稿")]
        XCTAssertEqual(WorkspaceLogic.addProblem(path: "/Users/me/Desktop/设计稿/", existing: existing), .alreadyAdded("设计稿"))
        XCTAssertEqual(WorkspaceLogic.addProblem(path: "/users/me/desktop/设计稿", existing: existing), .alreadyAdded("设计稿"))
        XCTAssertEqual(WorkspaceLogic.addProblem(path: "/Users/me/Desktop/设计稿/草稿", existing: existing), .insideExisting("设计稿"))
        XCTAssertNil(WorkspaceLogic.addProblem(path: "/Users/me/Desktop/设计稿2", existing: existing))
        XCTAssertNil(WorkspaceLogic.addProblem(path: "/Users/me/Desktop", existing: existing))
    }

    // MARK: - 离线判定

    func testExternalSourceOfflineWhenDriveNotMounted() {
        let source = WorkspaceSource(path: "/Volumes/闪迪/素材", kind: .external, volumeUUID: "U-1", volumeName: "闪迪",
                                     volumeCapacity: 1_000, relativePath: "素材")
        let state = WorkspaceLogic.availability(of: source, resolvedPath: nil, mounted: [volume("/Volumes/别的盘", uuid: "U-2")],
                                                isFolder: { _ in true })
        XCTAssertEqual(state, .offline(volumeName: "闪迪"))
        XCTAssertTrue(state.isOffline)
        XCTAssertFalse(state.isOnline)
    }

    func testExternalSourceComesBackAtNewMountPoint() throws {
        // 硬盘这次挂在 /Volumes/闪迪 1：靠卷 UUID + 相对路径找回来。
        let mount = try folder("闪迪 1")
        let dir = try folder("闪迪 1/素材")
        let source = WorkspaceSource(path: "/Volumes/闪迪/素材", kind: .external, volumeUUID: "u-1", volumeName: "闪迪",
                                     volumeCapacity: 1_000, relativePath: "素材")
        let state = WorkspaceLogic.availability(of: source, resolvedPath: nil, mounted: [volume(mount.path, uuid: "U-1")],
                                                isFolder: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(state, .online(path: FolderBackupLogic.standardized(dir.path)))
    }

    func testExternalSourceMissingWhenFolderGoneFromDrive() throws {
        let mount = try folder("盘")
        let source = WorkspaceSource(path: "/Volumes/盘/没了", kind: .external, volumeUUID: "U", relativePath: "没了")
        let state = WorkspaceLogic.availability(of: source, resolvedPath: nil, mounted: [volume(mount.path, uuid: "U")],
                                                isFolder: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(state, .missing)
    }

    func testExternalWithoutUUIDMatchesByNameAndCapacity() {
        let source = WorkspaceSource(path: "/Volumes/U盘/a", kind: .external, volumeUUID: nil, volumeName: "U盘",
                                     volumeCapacity: 64, relativePath: "a")
        XCTAssertTrue(WorkspaceLogic.matches(source, volume: volume("/Volumes/U盘", uuid: nil, name: "U盘", capacity: 64)))
        XCTAssertFalse(WorkspaceLogic.matches(source, volume: volume("/Volumes/U盘", uuid: nil, name: "U盘", capacity: 128)))
        let offline = WorkspaceLogic.availability(of: source, resolvedPath: nil, mounted: [], isFolder: { _ in true })
        XCTAssertEqual(offline, .offline(volumeName: "U盘"))
    }

    func testLocalSourceFollowsBookmarkAfterRename() throws {
        let dir = try folder("客户资料")
        try write("hi", "a.txt", in: dir)
        let source = WorkspaceLogic.makeSource(url: dir, volume: nil)
        let renamed = base.appendingPathComponent("客户资料（新）", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: renamed)
        var stale = false
        let resolved = try XCTUnwrap(source.bookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        })
        let state = WorkspaceLogic.availability(of: source, resolvedPath: resolved.path, mounted: [],
                                                isFolder: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(state.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       renamed.resolvingSymlinksInPath().path)
    }

    func testLocalSourceMissingAndTrash() {
        let source = WorkspaceSource(path: "/nowhere/项目")
        XCTAssertEqual(WorkspaceLogic.availability(of: source, resolvedPath: nil, mounted: [], isFolder: { _ in false }), .missing)
        let trashed = WorkspaceLogic.availability(of: source, resolvedPath: "/Users/me/.Trash/项目", mounted: [], isFolder: { _ in true })
        XCTAssertEqual(trashed, .online(path: "/nowhere/项目"), "书签指到废纸篓里不算；原路径还在时用原路径")
        let gone = WorkspaceLogic.availability(of: WorkspaceSource(path: "/Users/me/.Trash/项目"), resolvedPath: nil,
                                               mounted: [], isFolder: { _ in true })
        XCTAssertEqual(gone, .missing)
    }

    // MARK: - 统计

    func testFileKinds() {
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "JPG", type: nil), .image)
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "ai", type: nil), .image)
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "mp4", type: nil), .video)
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "xlsx", type: nil), .document)
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "pdf", type: nil), .document)
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "zip", type: nil), .other)
        XCTAssertEqual(WorkspaceLogic.fileKind(ext: "", type: nil), .other)
    }

    func testScanCountsWholeTree() throws {
        let root = try folder("设计稿")
        let now = Date()
        try write("1", "主视觉.png", in: root, modified: now.addingTimeInterval(-60))
        try write("22", "草稿/方案.pdf", in: root, modified: now.addingTimeInterval(-3600))
        try write("333", "草稿/深/样片.mov", in: root, modified: now.addingTimeInterval(-7200))
        try write("4444", "其他/数据.bin", in: root, modified: now.addingTimeInterval(-10))
        try write("hidden", ".DS_Store", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)
        let result = try XCTUnwrap(WorkspaceScanner.scan(root: root, now: now))
        let s = result.stats
        XCTAssertEqual(s.fileCount, 4, "隐藏文件不算")
        XCTAssertEqual(s.folderCount, 4, "草稿、草稿/深、其他、空文件夹")
        XCTAssertEqual(s.bytes, 10)
        XCTAssertEqual(s.images, 1)
        XCTAssertEqual(s.documents, 1)
        XCTAssertEqual(s.videos, 1)
        XCTAssertEqual(s.others, 1)
        XCTAssertEqual(s.cloudOnly, 0)
        XCTAssertFalse(s.truncated)
        XCTAssertEqual(s.scannedAt, now)
        XCTAssertEqual(s.recent.map(\.name), ["数据.bin", "主视觉.png", "方案.pdf", "样片.mov"], "新的在前")
        XCTAssertEqual(Set(result.folders.map(\.name)), ["草稿", "其他", "空文件夹"], "文件夹标签只列第一层")
        XCTAssertEqual(result.localFileCount, 4)
        XCTAssertEqual(result.localBytes, 10)
        XCTAssertEqual(result.byKind[.image]?.map(\.name), ["主视觉.png"])
        let lastModified = try XCTUnwrap(s.lastModified)
        XCTAssertEqual(lastModified.timeIntervalSince1970, now.addingTimeInterval(-10).timeIntervalSince1970, accuracy: 1)
    }

    func testScanCancelAndLimit() throws {
        let root = try folder("很多")
        for i in 0..<30 { try write("x", "f\(i).txt", in: root) }
        XCTAssertNil(WorkspaceScanner.scan(root: root, isCancelled: { true }), "取消了就不给结果")
        let limited = try XCTUnwrap(WorkspaceScanner.scan(root: root, maxItems: 10))
        XCTAssertTrue(limited.stats.truncated)
        XCTAssertEqual(limited.stats.fileCount, 10)
        let recentCapped = try XCTUnwrap(WorkspaceScanner.scan(root: root, recentLimit: 5))
        XCTAssertEqual(recentCapped.stats.recent.count, 5)
        XCTAssertEqual(recentCapped.stats.fileCount, 30)
    }

    func testTotalsUseCacheAndFlagUnscanned() {
        var a = WorkspaceSourceStats()
        a.fileCount = 3
        a.bytes = 300
        a.images = 2
        a.others = 1
        a.lastModified = Date(timeIntervalSince1970: 100)
        var b = WorkspaceSourceStats()
        b.fileCount = 2
        b.folderCount = 1
        b.bytes = 50
        b.videos = 2
        b.lastModified = Date(timeIntervalSince1970: 200)
        let t = WorkspaceLogic.totals([a, nil, b])
        XCTAssertEqual(t.sources, 3)
        XCTAssertEqual(t.fileCount, 5)
        XCTAssertEqual(t.folderCount, 1)
        XCTAssertEqual(t.bytes, 350)
        XCTAssertEqual(t.count(.image), 2)
        XCTAssertEqual(t.count(.video), 2)
        XCTAssertEqual(t.count(.other), 1)
        XCTAssertEqual(t.lastModified, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(t.incomplete)
        XCTAssertFalse(WorkspaceLogic.totals([a, b]).incomplete)
    }

    func testMergeRecentAcrossSources() {
        func e(_ name: String, _ t: TimeInterval) -> WorkspaceFileEntry {
            WorkspaceFileEntry(path: "/x/\(name)", name: name, modified: Date(timeIntervalSince1970: t), bytes: 1, kind: .other)
        }
        let merged = WorkspaceLogic.mergeRecent([[e("a", 3), e("b", 1)], [e("c", 2), e("a", 3)]], limit: 3)
        XCTAssertEqual(merged.map(\.name), ["a", "c", "b"])
    }

    // MARK: - 删除不碰原文件

    func testDeletingWorkspaceAndSourceNeverTouchesFiles() throws {
        let one = try folder("设计稿")
        let two = try folder("客户资料")
        try write("视觉", "主视觉.png", in: one)
        try write("报价", "报价/方案.pdf", in: two)
        let before = (fingerprint(one), fingerprint(two))

        var workspace = Workspace(name: "W", sources: [WorkspaceLogic.makeSource(url: one, volume: nil),
                                                         WorkspaceLogic.makeSource(url: two, volume: nil)])
        var file = WorkspacesFile(workspaces: [workspace, Workspace(name: "其他")], seededDefault: true)
        // 移除一个来源、删除整个工作区（和 WorkspaceStore 做的一样：只改配置），存一次再读回来。
        workspace.sources.removeAll { $0.path == FolderBackupLogic.standardized(two.path) }
        file.workspaces[0] = workspace
        file.workspaces.removeAll { $0.id == workspace.id }
        let decoded = WorkspaceCodec.decode(WorkspaceCodec.encode(file))
        XCTAssertEqual(decoded.workspaces.map(\.name), ["其他"])

        XCTAssertEqual(fingerprint(one), before.0)
        XCTAssertEqual(fingerprint(two), before.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.path))
    }

    // MARK: - 打包 ZIP

    func testUniqueZipNames() {
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        var taken: Set<String> = ["/tmp/x/默认工作区.zip", "/tmp/x/默认工作区 2.zip"]
        XCTAssertEqual(WorkspaceLogic.uniqueURL(for: "默认工作区.zip", in: folder, exists: { taken.contains($0) }).lastPathComponent,
                       "默认工作区 3.zip")
        taken = []
        XCTAssertEqual(WorkspaceLogic.uniqueURL(for: "默认工作区.zip", in: folder, exists: { taken.contains($0) }).lastPathComponent,
                       "默认工作区.zip")
        XCTAssertEqual(WorkspaceLogic.zipName(for: "a/b:c"), "a-b-c.zip")
        XCTAssertEqual(WorkspaceLogic.zipName(for: "  "), String(localized: "工作区") + ".zip")
        XCTAssertEqual(WorkspaceLogic.uniqueFolderNames(["设计稿", "设计稿", "a/b", ""]),
                       ["设计稿", "设计稿 2", "a-b", String(localized: "来源")])
    }

    func testZipNeverOverwritesAndLeavesSourcesUntouched() throws {
        let one = try folder("源/设计稿")
        let two = try folder("源/另一个/设计稿")
        try write("视觉", "主视觉 [1].png", in: one)
        try write("草稿", "草稿/a*.txt", in: one)
        try write("报价", "方案.pdf", in: two)
        let before = (fingerprint(one), fingerprint(two))
        let out = try folder("下载")
        let existing = try write("别动我", "默认工作区.zip", in: out)

        let target = WorkspaceLogic.uniqueURL(for: "默认工作区.zip", in: out)
        XCTAssertEqual(target.lastPathComponent, "默认工作区 2.zip")
        let first = WorkspaceZip.make(sources: [("设计稿", one), ("设计稿", two)], target: target)
        XCTAssertFalse(first.failed)
        XCTAssertEqual(first.files, 3)
        let firstURL = try XCTUnwrap(first.url)
        XCTAssertEqual(firstURL.lastPathComponent, "默认工作区 2.zip")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "别动我", "已有的同名 ZIP 不能被覆盖")

        // 再打一次：同一个目标名字已经有了，自动换成下一个编号。
        let second = WorkspaceZip.make(sources: [("设计稿", one)], target: target)
        XCTAssertEqual(second.url?.lastPathComponent, "默认工作区 3.zip")
        XCTAssertEqual(second.files, 2)

        // ZIP 里每个来源一个顶层文件夹，重名的加编号；没有留下临时文件。
        let entries = try ZipDirectoryReader.readEntries(at: firstURL).filter { !$0.isDirectory }
        let names = Set(entries.map { $0.path.precomposedStringWithCanonicalMapping })
        let expected = Set(["设计稿/主视觉 [1].png", "设计稿/草稿/a*.txt", "设计稿 2/方案.pdf"].map { $0.precomposedStringWithCanonicalMapping })
        XCTAssertEqual(names, expected)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(leftovers, [])

        XCTAssertEqual(fingerprint(one), before.0, "打包不改原文件")
        XCTAssertEqual(fingerprint(two), before.1)
    }

    func testZipCancelLeavesNothing() throws {
        let one = try folder("源")
        for i in 0..<5 { try write("x", "f\(i).txt", in: one) }
        let out = try folder("下载")
        let outcome = WorkspaceZip.make(sources: [("源", one)], target: out.appendingPathComponent("W.zip"), isCancelled: { true })
        XCTAssertTrue(outcome.cancelled)
        XCTAssertNil(outcome.url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testZipOfEmptySourceMakesNothing() throws {
        let one = try folder("空")
        let out = try folder("下载")
        let outcome = WorkspaceZip.make(sources: [("空", one)], target: out.appendingPathComponent("W.zip"))
        XCTAssertNil(outcome.url)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }
}
