import XCTest

final class FolderSizeInvalidationTests: XCTestCase {
    // MARK: 往上作废

    func testAncestorsStopAtRoot() {
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/Users/me/Docs/Work/a.txt", upTo: "/Users/me/Docs"),
                       ["/Users/me/Docs/Work", "/Users/me/Docs"])
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/Users/me/Docs/a.txt", upTo: "/Users/me/Docs/"),
                       ["/Users/me/Docs"])
    }

    func testAncestorsWithoutRootGoUpToTopLevelButNotSlash() {
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/Volumes/Disk/Archive/x", upTo: nil),
                       ["/Volumes/Disk/Archive", "/Volumes/Disk", "/Volumes"])
        // 不在 root 里面：和没有 root 一样
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/a/b/c", upTo: "/x"), ["/a/b", "/a"])
        // 「/ab」不算在「/a」里面
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/ab/c", upTo: "/a"), ["/ab"])
    }

    func testAncestorsEdgeCases() {
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/", upTo: nil), [])
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/top", upTo: nil), [])
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "relative/path", upTo: nil), [])
        // 变化就在根本身：根以上不管
        XCTAssertEqual(FolderSizeInvalidation.ancestors(of: "/r/root/", upTo: "/r/root"), [])
    }

    func testAffectedIncludesChangedPathsAndAncestors() {
        let set = FolderSizeInvalidation.affected(
            by: ["/Users/me/Docs/Work/Old/", "/Users/me/Docs/Photos/new.jpg", "/"], root: "/Users/me/Docs")
        XCTAssertEqual(set, ["/Users/me/Docs/Work/Old", "/Users/me/Docs/Work", "/Users/me/Docs",
                             "/Users/me/Docs/Photos/new.jpg", "/Users/me/Docs/Photos"])
        XCTAssertFalse(set.contains("/Users/me"))
        XCTAssertFalse(set.contains("/Users/me/Docs/Other"), "旁边的文件夹不受影响")
        XCTAssertTrue(FolderSizeInvalidation.affected(by: [], root: nil).isEmpty)
    }

    // MARK: 防抖与冷却

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testOwnOperationDebounced() {
        var scheduler = FolderRefreshScheduler(debounce: 1.5, maxDelay: 5, cooldown: 20)
        XCTAssertNil(scheduler.nextDeadline())
        scheduler.add(["/a", "/a/b"], now: t0, fromDiskWatcher: false)
        XCTAssertEqual(scheduler.nextDeadline(), t0.addingTimeInterval(1.5))
        XCTAssertTrue(scheduler.takeDue(now: t0.addingTimeInterval(1)).isEmpty, "防抖时间没到")
        // 又有变化：从最后一次变化起再等 1.5 秒
        scheduler.add(["/a/c"], now: t0.addingTimeInterval(1), fromDiskWatcher: false)
        XCTAssertEqual(scheduler.nextDeadline(), t0.addingTimeInterval(2.5))
        XCTAssertEqual(scheduler.takeDue(now: t0.addingTimeInterval(2.5)), ["/a", "/a/b", "/a/c"])
        XCTAssertTrue(scheduler.isEmpty)
        XCTAssertNil(scheduler.nextDeadline())
    }

    func testContinuousChangesStillRefreshWithinMaxDelay() {
        var scheduler = FolderRefreshScheduler(debounce: 1.5, maxDelay: 5, cooldown: 20)
        for i in 0..<10 {
            scheduler.add(["/busy"], now: t0.addingTimeInterval(Double(i)), fromDiskWatcher: false)
        }
        XCTAssertEqual(scheduler.nextDeadline(), t0.addingTimeInterval(5))
        XCTAssertEqual(scheduler.takeDue(now: t0.addingTimeInterval(5)), ["/busy"])
    }

    func testDiskWatcherCooldownPerFolder() {
        var scheduler = FolderRefreshScheduler(debounce: 1.5, maxDelay: 5, cooldown: 20)
        scheduler.add(["/lib"], now: t0, fromDiskWatcher: true)
        XCTAssertEqual(scheduler.takeDue(now: t0.addingTimeInterval(1.5)), ["/lib"], "第一次不用冷却")
        // 刚算过：磁盘监视再报变化，要等冷却
        scheduler.add(["/lib", "/other"], now: t0.addingTimeInterval(3), fromDiskWatcher: true)
        XCTAssertEqual(scheduler.takeDue(now: t0.addingTimeInterval(4.5)), ["/other"])
        XCTAssertEqual(scheduler.nextDeadline(), t0.addingTimeInterval(21.5))
        XCTAssertTrue(scheduler.takeDue(now: t0.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(scheduler.takeDue(now: t0.addingTimeInterval(21.5)), ["/lib"])
    }

    func testOwnOperationOverridesCooldown() {
        var scheduler = FolderRefreshScheduler(debounce: 1.5, maxDelay: 5, cooldown: 20)
        scheduler.add(["/lib"], now: t0, fromDiskWatcher: true)
        _ = scheduler.takeDue(now: t0.addingTimeInterval(2))
        scheduler.add(["/lib"], now: t0.addingTimeInterval(3), fromDiskWatcher: true)
        // 拾掇自己往里移了东西：不等冷却
        scheduler.add(["/lib"], now: t0.addingTimeInterval(3.5), fromDiskWatcher: false)
        XCTAssertEqual(scheduler.nextDeadline(), t0.addingTimeInterval(5))
        XCTAssertEqual(scheduler.takeDue(now: t0.addingTimeInterval(5)), ["/lib"])
    }

    func testSlowFoldersCoolDownLonger() {
        var scheduler = FolderRefreshScheduler(debounce: 1, maxDelay: 5, cooldown: 20)
        XCTAssertEqual(scheduler.cooldown(for: "/huge"), 20)
        scheduler.noteComputed("/huge", duration: 30)
        XCTAssertEqual(scheduler.cooldown(for: "/huge"), 90)
        scheduler.add(["/huge"], now: t0, fromDiskWatcher: true)
        _ = scheduler.takeDue(now: t0.addingTimeInterval(1))
        scheduler.add(["/huge"], now: t0.addingTimeInterval(2), fromDiskWatcher: true)
        XCTAssertEqual(scheduler.nextDeadline(), t0.addingTimeInterval(91))
    }
}
