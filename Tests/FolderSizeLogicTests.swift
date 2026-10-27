import XCTest

final class FolderSizeLogicTests: XCTestCase {
    // MARK: 类型

    func testClassifyByExtension() {
        XCTAssertEqual(SizeBucket.classify(name: "IMG_0001.HEIC"), .images)
        XCTAssertEqual(SizeBucket.classify(name: "clip.mov"), .videos)
        XCTAssertEqual(SizeBucket.classify(name: "song.flac"), .audio)
        XCTAssertEqual(SizeBucket.classify(name: "报告.docx"), .documents)
        XCTAssertEqual(SizeBucket.classify(name: "backup.tar.gz"), .archives)
        XCTAssertEqual(SizeBucket.classify(name: "Installer.dmg"), .installers)
        XCTAssertEqual(SizeBucket.classify(name: "Safari.app"), .installers)
        XCTAssertEqual(SizeBucket.classify(name: "main.swift"), .code)
        XCTAssertEqual(SizeBucket.classify(name: "index.ts"), .code)
        XCTAssertEqual(SizeBucket.classify(name: "Makefile"), .other)
        XCTAssertEqual(SizeBucket.classify(name: ".DS_Store"), .other)
        XCTAssertEqual(SizeBucket.classify(name: "data.unknownext"), .other)
        XCTAssertEqual(SizeBucket.classify(name: "Photos Library.photoslibrary"), .images)
    }

    func testEveryBucketHasTitle() {
        XCTAssertEqual(SizeBucket.allCases.count, 8)
        for bucket in SizeBucket.allCases { XCTAssertFalse(bucket.title.isEmpty) }
    }

    // MARK: 累加与分段

    func testAccumulatorCountsAndSizes() {
        var acc = FolderStatsAccumulator()
        acc.addFolder()
        acc.addFile(name: "a.jpg", bytes: 300)
        acc.addFile(name: "b.png", bytes: 100)
        acc.addFile(name: "c.mp4", bytes: 600)
        acc.addPackage(name: "Tool.app", bytes: 1000)
        acc.addFile(name: "empty.txt", bytes: 0)
        let stats = acc.stats
        XCTAssertEqual(stats.itemCount, 6)
        XCTAssertEqual(stats.size, 2000)
        XCTAssertEqual(stats.bytesByBucket[.images], 400)
        XCTAssertEqual(stats.bytesByBucket[.videos], 600)
        XCTAssertEqual(stats.bytesByBucket[.installers], 1000)
        XCTAssertNil(stats.bytesByBucket[.documents])
        XCTAssertFalse(stats.isPartial)
        acc.addPackage(name: "Locked.app", bytes: 0, partial: true)
        XCTAssertTrue(acc.stats.isPartial)
    }

    func testSegmentsSortedAndNormalized() {
        let segments = BucketSegment.make(from: [.images: 400, .videos: 600, .code: 0, .other: 1000])
        XCTAssertEqual(segments.map(\.bucket), [.other, .videos, .images])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertEqual(segments[0].percentText, "50%")
        XCTAssertEqual(segments[2].percentText, "20%")
    }

    func testSegmentsTieOrderStableAndEmpty() {
        let tie = BucketSegment.make(from: [.code: 10, .images: 10])
        XCTAssertEqual(tie.map(\.bucket), [.images, .code])
        XCTAssertTrue(BucketSegment.make(from: [:]).isEmpty)
        XCTAssertTrue(BucketSegment.make(from: [.images: 0]).isEmpty)
        let tiny = BucketSegment.make(from: [.other: 100_000, .code: 1])
        XCTAssertEqual(tiny.last?.percentText, "<1%")
    }

    func testSummaryText() {
        XCTAssertFalse(FolderStatsText.folderSummary(FolderStats()).isEmpty)
        var stats = FolderStats()
        stats.size = 2_000_000
        stats.itemCount = 12
        let text = FolderStatsText.folderSummary(stats)
        XCTAssertTrue(text.contains("12"), text)
        XCTAssertTrue(text.contains(" · "), text)
    }

    // MARK: 缓存

    func testCacheKeyedByStampAndAge() {
        var cache = FolderStatsCache(capacity: 10, maxAge: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let stamp = FileStamp(modified: t0, size: nil)
        var stats = FolderStats()
        stats.size = 42
        cache.insert("/a", stamp: stamp, stats: stats, now: t0)
        XCTAssertEqual(cache.lookup("/a", stamp: stamp, now: t0.addingTimeInterval(10)), stats)
        // 修改时间变了：作废
        let changed = FileStamp(modified: t0.addingTimeInterval(1), size: nil)
        XCTAssertNil(cache.lookup("/a", stamp: changed, now: t0.addingTimeInterval(10)))
        XCTAssertNil(cache.lookup("/a", stamp: stamp, now: t0.addingTimeInterval(10)), "作废后条目被删掉")
        // 过了存活时间：作废
        cache.insert("/b", stamp: stamp, stats: stats, now: t0)
        XCTAssertNil(cache.lookup("/b", stamp: stamp, now: t0.addingTimeInterval(61)))
        // 文件夹不在了
        cache.insert("/c", stamp: stamp, stats: stats, now: t0)
        XCTAssertNil(cache.lookup("/c", stamp: FileStamp(modified: nil, size: nil), now: t0))
    }

    func testCacheEvictsLeastRecentlyUsed() {
        var cache = FolderStatsCache(capacity: 2, maxAge: 1000)
        let now = Date()
        let stamp = FileStamp(modified: now, size: nil)
        cache.insert("/1", stamp: stamp, stats: FolderStats(), now: now)
        cache.insert("/2", stamp: stamp, stats: FolderStats(), now: now)
        _ = cache.lookup("/1", stamp: stamp, now: now)
        cache.insert("/3", stamp: stamp, stats: FolderStats(), now: now)
        XCTAssertNotNil(cache.entries["/1"])
        XCTAssertNil(cache.entries["/2"])
        XCTAssertNotNil(cache.entries["/3"])
    }

    func testCacheInvalidateAround() {
        var cache = FolderStatsCache()
        let stamp = FileStamp(modified: Date(), size: nil)
        for path in ["/u", "/u/docs", "/u/docs/a", "/u/docsx", "/u/pics"] {
            cache.insert(path, stamp: stamp, stats: FolderStats())
        }
        cache.invalidate(around: "/u/docs")
        XCTAssertEqual(Set(cache.entries.keys), ["/u/docsx", "/u/pics"])
    }

    func testCachePeekIgnoresStampAndDoesNotEvict() {
        var cache = FolderStatsCache(capacity: 10, maxAge: 1)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var stats = FolderStats()
        stats.size = 7
        cache.insert("/a", stamp: FileStamp(modified: t0, size: nil), stats: stats, now: t0)
        XCTAssertEqual(cache.peek("/a")?.size, 7)
        XCTAssertNil(cache.peek("/b"))
        XCTAssertNotNil(cache.entries["/a"], "peek 不删条目")
    }

    func testCacheMarkStaleKeepsPeekButFailsLookup() {
        var cache = FolderStatsCache(capacity: 10, maxAge: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let stamp = FileStamp(modified: t0, size: nil)
        var stats = FolderStats()
        stats.size = 42
        for path in ["/u", "/u/a", "/u/a/deep", "/u/b"] { cache.insert(path, stamp: stamp, stats: stats, now: t0) }
        XCTAssertTrue(cache.isFresh("/u/a", stamp: stamp, now: t0))
        cache.markStale(around: "/u/a/")
        // 它自己、里面的、上层的都过期；旁边的 /u/b 不受影响
        XCTAssertFalse(cache.isFresh("/u/a", stamp: stamp, now: t0))
        XCTAssertFalse(cache.isFresh("/u/a/deep", stamp: stamp, now: t0))
        XCTAssertFalse(cache.isFresh("/u", stamp: stamp, now: t0))
        XCTAssertTrue(cache.isFresh("/u/b", stamp: stamp, now: t0))
        // 旧值还能看（按大小排序用），isFresh 不删条目
        XCTAssertEqual(cache.peek("/u")?.size, 42)
        XCTAssertNotNil(cache.entries["/u/a"])
        // lookup 不认过期的
        XCTAssertNil(cache.lookup("/u", stamp: stamp, now: t0))
        XCTAssertEqual(cache.lookup("/u/b", stamp: stamp, now: t0)?.size, 42)
    }

    // MARK: 遍历磁盘

    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("FolderSizeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 恢复权限再删
        let locked = temp.appendingPathComponent("locked")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: temp)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = temp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func testWalkerCountsPackagesAsOneAndSkipsSymlinks() throws {
        try write("photos/a.jpg", bytes: 10_000)
        try write("photos/b.png", bytes: 20_000)
        try write("notes.txt", bytes: 5_000)
        try write("Tool.app/Contents/MacOS/Tool", bytes: 50_000)
        try write("Tool.app/Contents/Info.plist", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("link-to-photos"),
                                                   withDestinationURL: temp.appendingPathComponent("photos"))
        try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("loop"), withDestinationURL: temp)

        let stats = try XCTUnwrap(FolderWalker.stats(of: temp))
        // photos/、a.jpg、b.png、notes.txt、Tool.app = 5；替身不算，包里的不单独算
        XCTAssertEqual(stats.itemCount, 5)
        XCTAssertFalse(stats.isPartial)
        let images = stats.bytesByBucket[.images] ?? 0
        let docs = stats.bytesByBucket[.documents] ?? 0
        let app = stats.bytesByBucket[.installers] ?? 0
        XCTAssertGreaterThanOrEqual(images, 30_000)
        XCTAssertGreaterThanOrEqual(docs, 5_000)
        XCTAssertGreaterThanOrEqual(app, 51_000, "包的大小包含里面所有文件")
        XCTAssertEqual(stats.size, stats.bytesByBucket.values.reduce(0, +))
        // 替身没有被跟随：总量不会把 photos 算两遍
        XCTAssertLessThan(images, 60_000)

        let package = try XCTUnwrap(FolderWalker.packageSize(temp.appendingPathComponent("Tool.app")))
        XCTAssertEqual(package.bytes, app)
    }

    func testWalkerToleratesUnreadableFolder() throws {
        try write("ok.txt", bytes: 4_000)
        try write("locked/secret.txt", bytes: 4_000)
        let locked = temp.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        guard !FileManager.default.isReadableFile(atPath: locked.path) else {
            throw XCTSkip("以 root 运行，权限限制不生效")
        }
        let stats = try XCTUnwrap(FolderWalker.stats(of: temp))
        XCTAssertTrue(stats.isPartial)
        XCTAssertGreaterThanOrEqual(stats.itemCount, 2) // ok.txt + locked/
        XCTAssertGreaterThanOrEqual(stats.bytesByBucket[.documents] ?? 0, 4_000)
    }

    func testWalkerExcludedFolder() throws {
        try write("keep/a.txt", bytes: 4_000)
        try write("skip/b.txt", bytes: 4_000)
        let skip = temp.appendingPathComponent("skip")
        // 临时目录在 /var（指向 /private/var）下：两种写法都放进去
        let excluded: Set<String> = [skip.standardizedFileURL.path, skip.resolvingSymlinksInPath().path]
        let stats = try XCTUnwrap(FolderWalker.stats(of: temp, excluded: excluded))
        XCTAssertEqual(stats.itemCount, 3) // keep/、a.txt、skip/
        XCTAssertTrue(stats.isPartial)
    }

    func testWalkerCancels() throws {
        for i in 0..<600 { try write("many/\(i).txt", bytes: 1) }
        XCTAssertNil(FolderWalker.stats(of: temp, isCancelled: { true }))
        XCTAssertNotNil(FolderWalker.stats(of: temp, isCancelled: { false }))
    }

    func testWalkerEmptyAndMissing() throws {
        let empty = try XCTUnwrap(FolderWalker.stats(of: temp))
        XCTAssertEqual(empty.itemCount, 0)
        XCTAssertEqual(empty.size, 0)
        XCTAssertTrue(empty.segments.isEmpty)
        let missing = FolderWalker.stats(of: temp.appendingPathComponent("nope"))
        XCTAssertEqual(missing?.size ?? 0, 0)
    }
}
