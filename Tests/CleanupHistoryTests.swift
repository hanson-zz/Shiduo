import XCTest

final class CleanupHistoryLogicTests: XCTestCase {
    private func record(_ action: CleanupRecord.Action = .trash, daysAgo: Double = 0, now: Date = Date(),
                        original: String = "/Users/me/Downloads/a.dmg", current: String? = "/Users/me/.Trash/a.dmg",
                        root: String? = nil, alias: String? = nil) -> CleanupRecord {
        CleanupRecord(batchID: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), action: action, name: "a.dmg",
                      originalPath: original, currentPath: current, size: 100,
                      destinationName: action == .moveOut ? "Disk" : nil, destinationRoot: root, aliasPath: alias)
    }

    func testPruneDropsEntriesOlderThan30Days() {
        let now = Date()
        let list = [record(daysAgo: 0, now: now), record(daysAgo: 29.9, now: now), record(daysAgo: 30.1, now: now), record(daysAgo: 90, now: now)]
        let kept = CleanupHistoryLogic.prune(list, now: now)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.allSatisfy { now.timeIntervalSince($0.date) < 30 * 86_400 })
    }

    func testRestoreTargetUsesOriginalWhenFree() {
        let target = CleanupHistoryLogic.restoreTarget(for: "/a/b/报告.pdf") { _ in false }
        XCTAssertEqual(target, "/a/b/报告.pdf")
    }

    func testRestoreTargetAppendsSuffixBeforeExtension() {
        let taken: Set<String> = ["/a/b/报告.pdf", "/a/b/报告 (恢复).pdf"]
        XCTAssertEqual(CleanupHistoryLogic.restoreTarget(for: "/a/b/报告.pdf") { taken.contains($0) }, "/a/b/报告 (恢复 2).pdf")
        XCTAssertEqual(CleanupHistoryLogic.restoreTarget(for: "/a/b/报告.pdf") { $0 == "/a/b/报告.pdf" }, "/a/b/报告 (恢复).pdf")
        // 没有扩展名（文件夹）
        XCTAssertEqual(CleanupHistoryLogic.restoreTarget(for: "/a/Photos") { $0 == "/a/Photos" }, "/a/Photos (恢复)")
    }

    func testStatus() {
        let trash = record()
        XCTAssertEqual(CleanupHistoryLogic.status(of: trash) { _ in true }, .restorable)
        XCTAssertEqual(CleanupHistoryLogic.status(of: trash) { _ in false }, .trashEmptied)

        let move = record(.moveOut, current: "/Volumes/Disk/x/a.dmg", root: "/Volumes/Disk")
        XCTAssertEqual(CleanupHistoryLogic.status(of: move) { _ in false }, .destinationOffline)
        XCTAssertEqual(CleanupHistoryLogic.status(of: move) { $0 == "/Volumes/Disk" }, .missing)
        XCTAssertEqual(CleanupHistoryLogic.status(of: move) { _ in true }, .restorable)

        var done = trash
        done.restoredAt = Date()
        XCTAssertEqual(CleanupHistoryLogic.status(of: done) { _ in true }, .restored)
    }

    func testGroupByDayNewestFirst() {
        let now = Date()
        let groups = CleanupHistoryLogic.groupByDay([record(daysAgo: 2, now: now), record(daysAgo: 0, now: now), record(daysAgo: 0.001, now: now)])
        XCTAssertGreaterThanOrEqual(groups.count, 2)
        XCTAssertTrue(zip(groups, groups.dropFirst()).allSatisfy { $0.day > $1.day })
    }

    // MARK: 真文件

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRestoreMovesFileBackAndCreatesParent() throws {
        let fm = FileManager.default
        let trashDir = tmp.appendingPathComponent("Trash", isDirectory: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let trashed = trashDir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: trashed)
        let original = tmp.appendingPathComponent("gone/folder/a.txt").path

        let r = record(original: original, current: trashed.path)
        let restored = try CleanupHistoryLogic.restore(r)
        XCTAssertEqual(restored, original)
        XCTAssertTrue(fm.fileExists(atPath: original))
        XCTAssertFalse(fm.fileExists(atPath: trashed.path))
    }

    func testRestoreDoesNotOverwriteExistingFile() throws {
        let fm = FileManager.default
        let original = tmp.appendingPathComponent("a.txt")
        try Data("new".utf8).write(to: original)
        let trashed = tmp.appendingPathComponent("trashed-a.txt")
        try Data("old".utf8).write(to: trashed)

        let restored = try CleanupHistoryLogic.restore(record(original: original.path, current: trashed.path))
        XCTAssertEqual(restored, tmp.appendingPathComponent("a (恢复).txt").path)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOfFile: restored, encoding: .utf8), "old")
    }

    func testRestoreMoveOutRemovesAliasFirst() throws {
        let fm = FileManager.default
        let dest = tmp.appendingPathComponent("Disk/拾掇搬家/Downloads", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let moved = dest.appendingPathComponent("movie.mov")
        try Data(repeating: 7, count: 1024).write(to: moved)
        let original = tmp.appendingPathComponent("movie.mov")
        let bookmark = try moved.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: original)
        XCTAssertTrue(CleanupHistoryLogic.isAliasFile(original.path))

        let r = record(.moveOut, original: original.path, current: moved.path,
                       root: tmp.appendingPathComponent("Disk").path, alias: original.path)
        let restored = try CleanupHistoryLogic.restore(r)
        XCTAssertEqual(restored, original.path)
        XCTAssertFalse(CleanupHistoryLogic.isAliasFile(original.path))
        XCTAssertEqual(try Data(contentsOf: original).count, 1024)
    }

    func testRestoreKeepsRealFileAtAliasPath() throws {
        // 替身位置上如果已经是一个真文件，不能删它。
        let fm = FileManager.default
        let original = tmp.appendingPathComponent("doc.txt")
        try Data("real".utf8).write(to: original)
        let moved = tmp.appendingPathComponent("elsewhere-doc.txt")
        try Data("moved".utf8).write(to: moved)
        let r = record(.moveOut, original: original.path, current: moved.path, root: tmp.path, alias: original.path)
        let restored = try CleanupHistoryLogic.restore(r)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "real")
        XCTAssertTrue(fm.fileExists(atPath: restored))
        XCTAssertNotEqual(restored, original.path)
    }

    func testRestoreFailsWhenSourceMissing() {
        let r = record(original: tmp.appendingPathComponent("x").path, current: tmp.appendingPathComponent("nope").path)
        XCTAssertThrowsError(try CleanupHistoryLogic.restore(r))
    }

    @MainActor
    func testStorePersistsAndPrunes() throws {
        let file = tmp.appendingPathComponent("history.json")
        let store = CleanupHistory(fileURL: file)
        store.recordTrash([(name: "a", original: "/x/a", trashed: "/t/a", size: 1)])
        var old = record(daysAgo: 40)
        old.name = "old"
        store.add([old])
        XCTAssertEqual(store.records.map(\.name), ["a"])
        let reloaded = CleanupHistory(fileURL: file)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.originalPath, "/x/a")
    }
}
