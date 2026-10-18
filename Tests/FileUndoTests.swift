import XCTest

final class FileUndoTests: XCTestCase {
    private typealias Pair = FileUndoLogic.PathPair

    func testMoveSkipsTakenAndMissingNeverOverwrites() {
        var disk: Set<String> = ["/a/1", "/a/2", "/b/2"]
        var moves: [String] = []
        let outcome = FileUndoLogic.move(
            [Pair(from: "/a/1", to: "/b/1"), Pair(from: "/a/2", to: "/b/2"), Pair(from: "/a/3", to: "/b/3")],
            exists: { disk.contains($0) },
            move: { from, to in
                XCTAssertFalse(disk.contains(to))
                disk.remove(from); disk.insert(to); moves.append(from)
            })
        XCTAssertEqual(outcome.done, [Pair(from: "/a/1", to: "/b/1")])
        XCTAssertEqual(outcome.taken, ["2"])
        XCTAssertEqual(outcome.missing, ["3"])
        XCTAssertEqual(moves, ["/a/1"])
        XCTAssertTrue(disk.contains("/a/2") && disk.contains("/b/2"))
    }

    func testUndoReversesAndChainsInOrder() {
        // a→b、b→c 两步：撤销时先把 c 放回 b，再把 b 放回 a（按传入顺序，后面可以用前面刚空出来的位置）。
        var disk: Set<String> = ["/c"]
        let outcome = FileUndoLogic.undo([Pair(from: "/b", to: "/c"), Pair(from: "/a", to: "/b")],
                                         exists: { disk.contains($0) },
                                         move: { disk.remove($0); disk.insert($1) })
        XCTAssertEqual(outcome.done.count, 2)
        XCTAssertEqual(disk, ["/a"])
    }

    func testMoveFailureReported() {
        struct Boom: Error {}
        let outcome = FileUndoLogic.move([Pair(from: "/x/f", to: "/y/f")], exists: { $0 == "/x/f" },
                                         move: { _, _ in throw Boom() })
        XCTAssertEqual(outcome.failed, ["f"])
        XCTAssertEqual(outcome.skippedCount, 1)
    }

    func testEffectivelyEmptyAndNames() {
        XCTAssertTrue(FileUndoLogic.isEffectivelyEmpty([]))
        XCTAssertTrue(FileUndoLogic.isEffectivelyEmpty([".DS_Store"]))
        XCTAssertFalse(FileUndoLogic.isEffectivelyEmpty([".DS_Store", "a"]))
        XCTAssertEqual(FileUndoLogic.names(["a", "b"], limit: 5), "a、b")
        XCTAssertEqual(FileUndoLogic.names(["a", "b", "c"], limit: 2), "a、b…")
    }

    // MARK: 真文件

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoUndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMoveOnDiskRoundTripDoesNotOverwrite() throws {
        let fm = FileManager.default
        let a = tmp.appendingPathComponent("a.txt").path
        let b = tmp.appendingPathComponent("sub/a.txt").path
        try Data("one".utf8).write(to: URL(fileURLWithPath: a))
        let moved = FileUndoLogic.moveOnDisk([Pair(from: a, to: b)])
        XCTAssertEqual(moved.done.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: b))
        // 原位置又被一个新文件占了：撤销跳过，两边都不动
        try Data("new".utf8).write(to: URL(fileURLWithPath: a))
        let undo = FileUndoLogic.undo(moved.done, exists: { fm.fileExists(atPath: $0) },
                                      move: { try fm.moveItem(atPath: $0, toPath: $1) })
        XCTAssertEqual(undo.taken, ["a.txt"])
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "one")
    }

    func testHistoryRestoreSkipIfTaken() throws {
        let fm = FileManager.default
        let original = tmp.appendingPathComponent("doc.txt")
        try Data("occupant".utf8).write(to: original)
        let trashed = tmp.appendingPathComponent("trash-doc.txt")
        try Data("mine".utf8).write(to: trashed)
        let record = CleanupRecord(batchID: UUID(), date: Date(), action: .trash, name: "doc.txt",
                                   originalPath: original.path, currentPath: trashed.path, size: 4)
        XCTAssertThrowsError(try CleanupHistoryLogic.restore(record, skipIfTaken: true)) { error in
            XCTAssertEqual(error as? CleanupHistoryLogic.RestoreError, .originalTaken)
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "occupant")
        XCTAssertTrue(fm.fileExists(atPath: trashed.path))
        // 原位置空出来后就能放回原路径（不加「恢复」）
        try fm.removeItem(at: original)
        let restored = try CleanupHistoryLogic.restore(record, skipIfTaken: true)
        XCTAssertEqual(restored, original.path)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "mine")
    }

    func testHistoryRestoreSkipKeepsAlias() throws {
        let fm = FileManager.default
        let dest = tmp.appendingPathComponent("Disk", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let moved = dest.appendingPathComponent("movie.mov")
        try Data(repeating: 1, count: 64).write(to: moved)
        let original = tmp.appendingPathComponent("movie.mov")
        let bookmark = try moved.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: original)
        let record = CleanupRecord(batchID: UUID(), date: Date(), action: .moveOut, name: "movie.mov",
                                   originalPath: original.path, currentPath: moved.path, size: 64,
                                   destinationName: "Disk", destinationRoot: dest.path, aliasPath: original.path)
        // 原位置只有替身：可以放回（替身会被换掉）
        let restored = try CleanupHistoryLogic.restore(record, skipIfTaken: true)
        XCTAssertEqual(restored, original.path)
        XCTAssertFalse(CleanupHistoryLogic.isAliasFile(original.path))
    }
}
