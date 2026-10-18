import XCTest

final class DuplicateSafetyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ text: String) throws -> DuplicateSafety.Candidate {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return .init(path: url.path, size: Int64(text.utf8.count))
    }

    func testSafeWhenKeptUnchanged() throws {
        let a = try file("a.txt", "same content")
        let b = try file("b.txt", "same content")
        XCTAssertTrue(DuplicateSafety.isSafe(.init(kept: [a], extras: [b], exact: true)))
    }

    func testUnsafeWhenKeptMissing() throws {
        let a = try file("a.txt", "same content")
        let b = try file("b.txt", "same content")
        try FileManager.default.removeItem(atPath: a.path)
        XCTAssertFalse(DuplicateSafety.isSafe(.init(kept: [a], extras: [b], exact: true)))
        XCTAssertFalse(DuplicateSafety.isSafe(.init(kept: [a], extras: [b], exact: false)))
    }

    func testUnsafeWhenKeptChangedSize() throws {
        let a = try file("a.txt", "same content")
        let b = try file("b.txt", "same content")
        try Data("edited, longer content".utf8).write(to: URL(fileURLWithPath: a.path))
        XCTAssertFalse(DuplicateSafety.isSafe(.init(kept: [a], extras: [b], exact: true)))
    }

    func testUnsafeWhenContentDiffersWithSameSize() throws {
        let a = try file("a.txt", "same content")
        let b = try file("b.txt", "same content")
        try Data("SAME CONTENT".utf8).write(to: URL(fileURLWithPath: a.path))
        XCTAssertFalse(DuplicateSafety.isSafe(.init(kept: [a], extras: [b], exact: true)))
        // 相似照片不比内容，只看保留的还在、大小没变。
        XCTAssertTrue(DuplicateSafety.isSafe(.init(kept: [a], extras: [b], exact: false)))
    }

    func testNoKeptIsUnsafe() throws {
        let b = try file("b.txt", "x")
        XCTAssertFalse(DuplicateSafety.isSafe(.init(kept: [], extras: [b], exact: true)))
    }
}
