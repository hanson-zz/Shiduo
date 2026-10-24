import XCTest

final class LibraryLoadTests: XCTestCase {
    // MARK: 路径规整的快速路径

    func testAlreadyStandardPathsSkipFoundation() {
        let normal = [
            "/Users/me/Pictures/a.png",
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/设计/海报 1.psd",
            "/Users/me/Desktop/截屏2026-10-24 11.52.00.png",
            "/Volumes/Disk/x.mov",
            "/",
        ]
        for path in normal {
            XCTAssertTrue(LibraryScope.isAlreadyStandard(path), path)
            XCTAssertEqual(LibraryScope.standardize(path), path)
        }
    }

    func testIrregularPathsStillStandardized() {
        let odd = ["/Users/me/Documents/Old/", "/Users/me//a.png", "/Users/me/./a.png", "/Users/me/x/../a.png",
                   "~/a.png", "/private/tmp/a.png", "relative/a.png", "/Users/me/.", ""]
        for path in odd {
            XCTAssertFalse(LibraryScope.isAlreadyStandard(path), path)
        }
        XCTAssertEqual(LibraryScope.standardize("/Users/me/Documents/Old/"), "/Users/me/Documents/Old")
        XCTAssertEqual(LibraryScope.standardize("/Users/me//a.png"), "/Users/me/a.png")
        XCTAssertEqual(LibraryScope.standardize("/Users/me/./a.png"), "/Users/me/a.png")
    }

    /// 快速路径和 Foundation 的结果一样（普通的绝对路径）。
    func testFastPathMatchesFoundation() {
        let paths = ["/Users/me/Pictures/a.png", "/Users/me/Movies/My Movie.mov", "/Applications/Foo.app/Contents/x.png"]
        for path in paths {
            var slow = (path as NSString).standardizingPath
            while slow.count > 1 && slow.hasSuffix("/") { slow.removeLast() }
            XCTAssertEqual(LibraryScope.standardize(path), slow)
        }
    }

    // MARK: 预先算好的范围

    func testMatcherAgreesWithScope() {
        var scope = LibraryScope(home: "/Users/me", disabled: [.downloads])
        scope.exclude("/Users/me/Documents/Old")
        scope.include("/Users/me/Documents/Old/Keep")
        scope.include("/Users/me/Projects")
        let matcher = LibraryScope.Matcher(scope)
        let paths = [
            "/Users/me/Desktop/a.png", "/Users/me/Downloads/b.png", "/Users/me/Documents/Old/c.pdf",
            "/Users/me/Documents/Old/Keep/d.pdf", "/Users/me/Projects/e.png", "/Users/me/Projects/.git/f",
            "/Users/me/Library/Caches/g.png", "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/h.png",
            "/Users/me/Library/Mobile Documents/iCloud~foo/Documents/i.png", "/Users/me/Library/Mobile Documents/iCloud~foo/j.png",
            "/Users/me/Pictures/Photos Library.photoslibrary/originals/k.heic", "/Users/me/l.png", "/Volumes/X/m.png",
        ]
        for path in paths {
            XCTAssertEqual(matcher.includes(path), scope.includes(path), path)
            XCTAssertEqual(matcher.isNoise(path), scope.isNoise(path), path)
        }
        XCTAssertTrue(matcher.includes("/Users/me/Documents/Old/Keep/d.pdf"))
        XCTAssertFalse(matcher.includes("/Users/me/Documents/Old/c.pdf"))
        XCTAssertFalse(matcher.includes("/Users/me/Downloads/b.png"))
    }

    // MARK: 第一屏

    func testFirstScreenOnlyForDefaultNewestFirst() {
        let key = "kMDItemFSContentChangeDate"
        XCTAssertTrue(LibraryFirstScreen.eligible(sortKey: key, defaultKey: key, ascending: false, isRecents: false))
        XCTAssertFalse(LibraryFirstScreen.eligible(sortKey: key, defaultKey: key, ascending: true, isRecents: false))
        XCTAssertFalse(LibraryFirstScreen.eligible(sortKey: "kMDItemFSName", defaultKey: key, ascending: false, isRecents: false))
        XCTAssertFalse(LibraryFirstScreen.eligible(sortKey: key, defaultKey: key, ascending: false, isRecents: true))
        XCTAssertFalse(LibraryFirstScreen.eligible(sortKey: key, defaultKey: key, ascending: false, isRecents: false, offset: 3000))
    }

    func testFirstScreenWindowsAndCount() {
        XCTAssertEqual(LibraryFirstScreen.windowDays, LibraryFirstScreen.windowDays.sorted())
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(LibraryFirstScreen.cutoff(days: 30, now: now), now.addingTimeInterval(-30 * 86_400))
        XCTAssertTrue(LibraryFirstScreen.isEnough(found: LibraryFirstScreen.count))
        XCTAssertFalse(LibraryFirstScreen.isEnough(found: LibraryFirstScreen.count - 1))
        XCTAssertLessThan(LibraryFirstScreen.count, 3000)
    }

    // MARK: 页面缓存

    func testPageCacheEvictsLeastRecentlyUsed() {
        var cache = LibraryPageCache<Int>(capacity: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)   // a 变成最近用过
        cache.set(3, for: "c")                     // 扔掉 b
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.count, 2)
        cache.update { $0 * 10 }
        XCTAssertEqual(cache.value(for: "a"), 10)
        cache.set(4, for: "a")
        XCTAssertEqual(cache.value(for: "a"), 4)
        XCTAssertEqual(cache.count, 2)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(for: "c"))
    }

    func testCacheKeyChangesWithEveryInput() {
        let scope = LibraryScope(home: "/Users/me")
        let base = LibraryCacheKey.make(category: "images", sub: nil, sort: "d#false", scope: scope)
        XCTAssertEqual(base, LibraryCacheKey.make(category: "images", sub: nil, sort: "d#false", scope: scope))
        XCTAssertNotEqual(base, LibraryCacheKey.make(category: "videos", sub: nil, sort: "d#false", scope: scope))
        XCTAssertNotEqual(base, LibraryCacheKey.make(category: "images", sub: "photo", sort: "d#false", scope: scope))
        XCTAssertNotEqual(base, LibraryCacheKey.make(category: "images", sub: nil, sort: "d#true", scope: scope))
        var other = scope
        other.hideSmallImages = false
        XCTAssertNotEqual(base, LibraryCacheKey.make(category: "images", sub: nil, sort: "d#false", scope: other))
        other = scope
        other.exclude("/Users/me/Documents/Old")
        XCTAssertNotEqual(base, LibraryCacheKey.make(category: "images", sub: nil, sort: "d#false", scope: other))
        XCTAssertNotEqual(base, LibraryCacheKey.make(category: "images", sub: nil, sort: "d#false",
                                                     scope: LibraryScope(home: "/Users/me", disabled: [.music])))
    }

    // MARK: 加载下一页时只排新来的

    func testMergeEqualsStableSortOfConcatenation() {
        struct Item: Equatable { let key: Int; let tag: String }
        var generator = SystemRandomNumberGenerator()
        for round in 0..<200 {
            let a = (0..<Int.random(in: 0...30, using: &generator)).map { Item(key: Int.random(in: 0...10, using: &generator), tag: "a\(round)-\($0)") }
            let b = (0..<Int.random(in: 0...30, using: &generator)).map { Item(key: Int.random(in: 0...10, using: &generator), tag: "b\(round)-\($0)") }
            let less: (Item, Item) -> Bool = { $0.key > $1.key }   // 从大到小（像按日期从新到旧）
            let expected = (a + b).enumerated().sorted { l, r in
                less(l.element, r.element) || (!less(r.element, l.element) && l.offset < r.offset)
            }.map(\.element)
            let merged = SortMerge.merge(a.enumerated().sorted { l, r in
                less(l.element, r.element) || (!less(r.element, l.element) && l.offset < r.offset)
            }.map(\.element), b.enumerated().sorted { l, r in
                less(l.element, r.element) || (!less(r.element, l.element) && l.offset < r.offset)
            }.map(\.element), by: less)
            XCTAssertEqual(merged, expected)
        }
    }
}
