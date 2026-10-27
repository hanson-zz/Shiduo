import CryptoKit
import XCTest

/// 智能清理进阶：开发缓存白名单、重复文件分组和保留哪份、已删 App 残留判断、旧 node_modules。
final class AdvancedCleanupLogicTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("adv-cleanup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private var home: String { root.path }

    @discardableResult
    private func makeFile(_ rel: String, bytes: Int = 16, fill: UInt8 = 0x61) throws -> String {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url.path
    }

    @discardableResult
    private func makeDir(_ rel: String) throws -> String {
        let url = root.appendingPathComponent(rel, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func setDate(_ path: String, daysAgo: Double, now: Date = Date()) throws {
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path)
    }

    private func names(_ paths: [String]) -> [String] {
        paths.map { ($0 as NSString).lastPathComponent }.sorted()
    }

    // MARK: - 开发缓存

    func testWhitelistMatching() {
        let h = "/Users/me"
        XCTAssertTrue(DevCacheLogic.isWhitelisted("/Users/me/Library/Developer/Xcode/DerivedData/App-abc", home: h))
        XCTAssertTrue(DevCacheLogic.isWhitelisted("/Users/me/Library/Caches/Homebrew", home: h))
        XCTAssertTrue(DevCacheLogic.isWhitelisted("/Users/me/Library/Caches/Homebrew/", home: h))
        XCTAssertTrue(DevCacheLogic.isWhitelisted("/Users/me/.npm/_cacache", home: h))
        XCTAssertTrue(DevCacheLogic.isWhitelisted("/Users/me/.gradle/caches/modules-2", home: h))
        XCTAssertTrue(DevCacheLogic.isWhitelisted("/Users/me/Library/Caches/go-build", home: h))
        // 白名单的上一层、旁边的文件夹、名字只是开头相同的，都不算。
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/me/Library/Caches", home: h))
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/me/Library/Developer/Xcode", home: h))
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/me/Library/Caches/HomebrewX", home: h))
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/me/.npm", home: h))
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/me/Library/Preferences/com.foo.plist", home: h))
        // 用「..」绕出去的不认。
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/me/Library/Caches/Homebrew/../../Preferences", home: h))
        // 别人的个人文件夹不算。
        XCTAssertFalse(DevCacheLogic.isWhitelisted("/Users/other/Library/Caches/Homebrew", home: h))
        XCTAssertFalse(DevCacheLogic.isWhitelisted("", home: h))
    }

    func testDevCacheCandidates() throws {
        let now = Date()
        try makeFile("Library/Developer/Xcode/DerivedData/AppA-xyz/Build/a.o")
        try makeFile("Library/Developer/Xcode/DerivedData/AppB-xyz/Index/b.idx")
        try makeFile("Library/Caches/Homebrew/downloads/x.tar.gz")
        try makeFile(".npm/_cacache/index-v5/aa")
        // 空的缓存文件夹不列。
        try makeDir("Library/Caches/pip")
        // 白名单以外的不碰。
        try makeFile("Library/Caches/com.example.app/cache.db")
        try makeFile("Library/Developer/Xcode/UserData/keep.plist")
        // Xcode 归档：只列半年以前的。
        let oldArchive = try makeDir("Library/Developer/Xcode/Archives/2025-01-02/Old.xcarchive")
        let newArchive = try makeDir("Library/Developer/Xcode/Archives/2026-10-01/New.xcarchive")
        try setDate(oldArchive, daysAgo: 400, now: now)
        try setDate(newArchive, daysAgo: 5, now: now)
        // 白名单位置本身是替身：整个跳过。
        let elsewhere = try makeDir("Elsewhere/yarn")
        try makeFile("Elsewhere/yarn/v6/pkg")
        try makeDir("Library/Caches")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Library/Caches/Yarn").path, withDestinationPath: elsewhere)

        let found = DevCacheLogic.candidates(home: home, now: now, fileManager: fm)
        XCTAssertEqual(names(found.map(\.path)), ["AppA-xyz", "AppB-xyz", "Homebrew", "Old.xcarchive", "_cacache"])
        XCTAssertTrue(found.allSatisfy { DevCacheLogic.isWhitelisted($0.path, home: home) })
        XCTAssertEqual(found.first { $0.path.hasSuffix("Homebrew") }?.label, "Homebrew")
        XCTAssertEqual(found.first { $0.path.hasSuffix("AppA-xyz") }?.label, "Xcode DerivedData")
    }

    func testDevCacheNothingFoundIsEmpty() {
        // 个人文件夹里没有任何开发缓存：结果为空（卡片因此隐藏）。
        XCTAssertTrue(DevCacheLogic.candidates(home: home, fileManager: fm).isEmpty)
    }

    func testMailDownloads() throws {
        try makeFile("Library/Mail Downloads/1A2B-UUID/合同.pdf")
        try makeFile("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/C3D4/photo.jpg")
        try makeFile("Library/Mail Downloads/.DS_Store")
        let all = MailDownloadsLogic.candidates(home: home, skipContainer: false, fileManager: fm)
        XCTAssertEqual(Set(all.map(\.title)), ["合同.pdf", "photo.jpg"])
        // 没有完全磁盘访问权限：不碰「邮件」的容器。
        let noFDA = MailDownloadsLogic.candidates(home: home, skipContainer: true, fileManager: fm)
        XCTAssertEqual(noFDA.map(\.title), ["合同.pdf"])
        XCTAssertTrue(all.allSatisfy { MailDownloadsLogic.isInside($0.path, home: home) })
        XCTAssertFalse(MailDownloadsLogic.isInside(home + "/Library/Mail Downloads", home: home))
        XCTAssertFalse(MailDownloadsLogic.isInside(home + "/Library/Mail Downloads/../Preferences/x", home: home))
    }

    // MARK: - 重复文件

    private func sha(_ path: String, _ limit: Int?) -> String? {
        guard let data = fm.contents(atPath: path) else { return nil }
        let part = limit.map { data.prefix($0) } ?? data[...]
        return SHA256.hash(data: part).map { String(format: "%02x", $0) }.joined()
    }

    func testDuplicateGroupingBySizeThenHash() throws {
        let a1 = try makeFile("a/one.bin", bytes: 1000, fill: 1)
        let a2 = try makeFile("b/one copy.bin", bytes: 1000, fill: 1)
        let a3 = try makeFile("c/one again.bin", bytes: 1000, fill: 1)
        // 同样大小、内容不同：不算重复。
        let different = try makeFile("d/other.bin", bytes: 1000, fill: 2)
        // 大文件：开头 64 KB 一样、后面不同，要比完整指纹才能分开。
        var big1 = Data(repeating: 7, count: 100_000)
        var big2 = big1
        big1[99_999] = 1
        big2[99_999] = 2
        let b1 = root.appendingPathComponent("e/big1.bin")
        let b2 = root.appendingPathComponent("e/big2.bin")
        let b3 = root.appendingPathComponent("f/big1-copy.bin")
        try fm.createDirectory(at: b1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: b3.deletingLastPathComponent(), withIntermediateDirectories: true)
        try big1.write(to: b1)
        try big2.write(to: b2)
        try big1.write(to: b3)
        let lonely = try makeFile("g/lonely.bin", bytes: 1234)
        let empty1 = try makeFile("h/empty1", bytes: 0)
        let empty2 = try makeFile("h/empty2", bytes: 0)

        let candidates = [a1, a2, a3, different, b1.path, b2.path, b3.path, lonely, empty1, empty2, a1].map { path -> DuplicateGrouping.Candidate in
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return DuplicateGrouping.Candidate(path: path, size: size)
        }
        var reads = 0
        let groups = DuplicateGrouping.group(candidates, hash: { path, limit in
            reads += 1
            return self.sha(path, limit)
        })
        XCTAssertEqual(groups.count, 2)
        // 可腾出多的组在前：大文件一组（2 份 × 100 KB）> 小文件一组（3 份 × 1 KB）。
        XCTAssertEqual(Set(groups[0].map(\.path)), [b1.path, b3.path])
        XCTAssertEqual(Set(groups[1].map(\.path)), [a1, a2, a3])
        XCTAssertFalse(groups.joined().contains { $0.path == different || $0.path == lonely || $0.path == empty1 })
        XCTAssertGreaterThan(reads, 0)
    }

    func testDuplicateGroupingCancelled() throws {
        let a = try makeFile("x/a", bytes: 10)
        let b = try makeFile("y/b", bytes: 10)
        let groups = DuplicateGrouping.group(
            [.init(path: a, size: 10), .init(path: b, size: 10)],
            hash: { path, limit in self.sha(path, limit) },
            isCancelled: { true }
        )
        XCTAssertTrue(groups.isEmpty)
    }

    func testKeepPickPrefersMostRecentlyOpened() {
        let now = Date()
        let copies = [
            DuplicateKeepLogic.Copy(path: "/a/old-opened", lastUsed: now.addingTimeInterval(-86_400 * 30), modified: now),
            DuplicateKeepLogic.Copy(path: "/b/recent-opened", lastUsed: now.addingTimeInterval(-3_600), modified: now.addingTimeInterval(-86_400 * 300)),
            DuplicateKeepLogic.Copy(path: "/c/never-opened", lastUsed: nil, modified: now.addingTimeInterval(-86_400 * 2)),
        ]
        XCTAssertEqual(DuplicateKeepLogic.keepIndex(copies), 1)
        XCTAssertEqual(DuplicateKeepLogic.ordered(copies).first?.path, "/b/recent-opened")
    }

    func testKeepPickFallsBackToModifiedAndIsStable() {
        let now = Date()
        // 都没有打开记录：看修改时间。
        let byModified = [
            DuplicateKeepLogic.Copy(path: "/x/older", lastUsed: nil, modified: now.addingTimeInterval(-500)),
            DuplicateKeepLogic.Copy(path: "/x/newer", lastUsed: nil, modified: now.addingTimeInterval(-10)),
        ]
        XCTAssertEqual(DuplicateKeepLogic.keepIndex(byModified), 1)
        // 时间一样：路径短的，再按字母。
        let tie = [
            DuplicateKeepLogic.Copy(path: "/long/path/file", lastUsed: nil, modified: now),
            DuplicateKeepLogic.Copy(path: "/b/file", lastUsed: nil, modified: now),
            DuplicateKeepLogic.Copy(path: "/a/file", lastUsed: nil, modified: now),
        ]
        XCTAssertEqual(DuplicateKeepLogic.ordered(tie).map(\.path), ["/a/file", "/b/file", "/long/path/file"])
        XCTAssertNil(DuplicateKeepLogic.keepIndex([]))
    }

    // MARK: - 已删 App 残留

    func testBundleIDFromEntry() {
        XCTAssertEqual(OrphanLogic.bundleID(fromEntry: "com.foo.Bar.plist", in: .preferences), "com.foo.Bar")
        XCTAssertEqual(OrphanLogic.bundleID(fromEntry: "com.foo.Bar.savedState", in: .savedState), "com.foo.Bar")
        XCTAssertEqual(OrphanLogic.bundleID(fromEntry: "com.foo.Bar.binarycookies", in: .httpStorages), "com.foo.Bar")
        XCTAssertEqual(OrphanLogic.bundleID(fromEntry: "ABCDE12345.com.foo.shared", in: .groupContainers), "com.foo.shared")
        XCTAssertEqual(OrphanLogic.bundleID(fromEntry: "group.com.foo.bar", in: .groupContainers), "com.foo.bar")
        // 含糊的名字一律不认。
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "Google", in: .applicationSupport))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "CrashReporter", in: .applicationSupport))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "com.foo", in: .caches))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "Figma Desktop.app", in: .caches))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "ByHost", in: .preferences))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: ".GlobalPreferences.plist", in: .preferences))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "UBF8T346G9.Office", in: .groupContainers))
        XCTAssertNil(OrphanLogic.bundleID(fromEntry: "com.foo bar.baz", in: .caches))
    }

    func testOrphanMatching() {
        let now = Date()
        let old = now.addingTimeInterval(-86_400 * 120)
        let installed = OrphanLogic.Installed(bundleIDs: ["com.google.Chrome", "com.figma.Desktop", "com.tencent.xinWeChat"])
        func orphan(_ id: String, modified: Date? = nil, known: Bool = false) -> Bool {
            OrphanLogic.isOrphan(bundleID: id, installed: installed, ownBundleID: "io.github.hanson-zz.shiduo",
                                 modified: modified ?? old, now: now, knownToSystem: { _ in known })
        }
        // 真正的残留：没装、没人认得、很久没变。
        XCTAssertTrue(orphan("com.sketchapp.Sketch"))
        XCTAssertTrue(orphan("com.example.GoneApp"))
        // 装着的（大小写不同也算）、它的辅助程序、同一开发商的其他东西：不算。
        XCTAssertFalse(orphan("com.google.Chrome"))
        XCTAssertFalse(orphan("com.google.chrome"))
        XCTAssertFalse(orphan("com.google.Chrome.helper"))
        XCTAssertFalse(orphan("com.google.drivefs"))
        XCTAssertFalse(orphan("com.tencent.xinWeChat.WeChatMacShare"))
        // 苹果自己的、常见工具借用的、拾掇自己的：不算。
        XCTAssertFalse(orphan("com.apple.Safari"))
        XCTAssertFalse(orphan("org.swift.swiftpm"))
        XCTAssertFalse(orphan("io.github.hanson-zz.shiduo"))
        XCTAssertFalse(orphan("io.github.someone.else"))
        // 最近 30 天还在变、系统还认得、没有时间信息：拿不准，不算。
        XCTAssertFalse(orphan("com.example.GoneApp", modified: now.addingTimeInterval(-86_400 * 3)))
        XCTAssertFalse(orphan("com.example.GoneApp", known: true))
        XCTAssertFalse(OrphanLogic.isOrphan(bundleID: "com.example.GoneApp", installed: installed, ownBundleID: "",
                                            modified: nil, now: now, knownToSystem: { _ in false }))
        // 不像 Bundle ID 的不判断。
        XCTAssertFalse(orphan("Google"))
    }

    // MARK: - 旧 node_modules

    func testNodeModulesStaleAndNesting() throws {
        let now = Date()
        // 旧项目：90 天以上没改动。
        try makeFile("Projects/old-site/package.json")
        try makeFile("Projects/old-site/src/index.js")
        try makeFile("Projects/old-site/node_modules/react/index.js")
        // 嵌套在 node_modules 里的 node_modules 不单独列。
        try makeFile("Projects/old-site/node_modules/react/node_modules/loose/index.js")
        try makeFile("Projects/old-site/node_modules/react/package.json")
        // 新项目：src 里最近改过。
        try makeFile("Projects/new-app/package.json")
        try makeFile("Projects/new-app/src/app.js")
        try makeFile("Projects/new-app/node_modules/vue/index.js")
        // 没有 package.json：不算项目。
        try makeFile("Stuff/node_modules/x.js")
        // 资源库、隐藏文件夹里的不找。
        try makeFile("Library/App/package.json")
        try makeFile("Library/App/node_modules/x.js")
        try makeFile(".hidden/proj/package.json")
        try makeFile(".hidden/proj/node_modules/x.js")

        // 把所有东西的修改时间设成 200 天前（从深到浅，免得改子项又刷新上层）。
        let all = (fm.enumerator(atPath: home)?.allObjects as? [String] ?? []).sorted { $0.count > $1.count }
        for rel in all { try setDate(root.appendingPathComponent(rel).path, daysAgo: 200, now: now) }
        try setDate(home, daysAgo: 200, now: now)
        // 新项目里有一个文件 3 天前改过。
        try setDate(root.appendingPathComponent("Projects/new-app/src/app.js").path, daysAgo: 3, now: now)
        // 旧项目的 node_modules 里最近装过东西：不影响（不算 node_modules 里的改动）。
        try setDate(root.appendingPathComponent("Projects/old-site/node_modules/react/index.js").path, daysAgo: 1, now: now)

        let hits = NodeModulesLogic.findStale(home: home, now: now, staleDays: 90, fileManager: fm)
        XCTAssertEqual(hits.map(\.projectName), ["old-site"])
        XCTAssertEqual((hits.first?.modulesPath as NSString?)?.lastPathComponent, "node_modules")
        if let last = hits.first?.lastModified {
            XCTAssertTrue((199...200).contains(NodeModulesLogic.daysSince(last, now: now)))
        }
    }

    func testNodeModulesRecentProjectDirIsNotStale() throws {
        let now = Date()
        try makeFile("p/package.json")
        try makeFile("p/node_modules/a.js")
        // 全是新的：不列。
        XCTAssertTrue(NodeModulesLogic.findStale(home: home, now: now, fileManager: fm).isEmpty)
    }

    func testLastModifiedIfStaleGivesUpWhenTooMany() throws {
        let now = Date()
        for i in 0..<5 { try makeFile("proj/f\(i).txt") }
        let all = (fm.enumerator(atPath: home)?.allObjects as? [String] ?? []).sorted { $0.count > $1.count }
        for rel in all { try setDate(root.appendingPathComponent(rel).path, daysAgo: 200, now: now) }
        let project = root.appendingPathComponent("proj")
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        XCTAssertNotNil(NodeModulesLogic.lastModifiedIfStale(project: project, cutoff: cutoff, fileManager: fm))
        // 东西太多没看完：拿不准，不列。
        XCTAssertNil(NodeModulesLogic.lastModifiedIfStale(project: project, cutoff: cutoff, entryLimit: 3, fileManager: fm))
    }

    // MARK: - 同一个文件只算一张卡片（文件夹里面的也算）

    func testDedupeNested() {
        let out = SmartCleanupLogic.dedupe([
            ("mail", ["/u/Library/Mail Downloads/A"]),
            ("video", ["/u/Library/Mail Downloads/A/big.mov", "/u/Movies/x.mov"]),
            ("again", ["/u/Movies/x.mov", "/u/Movies/x.mov2"]),
        ])
        XCTAssertEqual(out[0].1, ["/u/Library/Mail Downloads/A"])
        XCTAssertEqual(out[1].1, ["/u/Movies/x.mov"])
        XCTAssertEqual(out[2].1, ["/u/Movies/x.mov2"])
    }
}
