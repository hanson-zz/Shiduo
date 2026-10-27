import XCTest

/// 压缩包浏览：zip 目录（ZIP64、UTF-8 标记、GBK 名字）、文件夹树、系统 tar 列表、解压。
final class ArchiveLogicTests: XCTestCase {
    // MARK: 手工拼一个 zip（不压缩），方便造 GBK 名字和 ZIP64 字段

    private struct ZipBuilder {
        var body = Data()
        var central = Data()
        var count = 0

        static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        static func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }) }

        /// madeBy 高字节：0 = DOS（Windows），3 = Unix。
        mutating func add(_ nameBytes: [UInt8], _ content: [UInt8], utf8Flag: Bool = false,
                          host: UInt8 = 3, zip64: Bool = false, directory: Bool = false) {
            let offset = UInt64(body.count)
            let crc = CRC32.checksum(content)
            let flags: UInt16 = utf8Flag ? 0x0800 : 0
            let size = UInt32(content.count)
            var local = Data()
            local += Self.le32(0x0403_4B50) + Self.le16(20) + Self.le16(flags) + Self.le16(0)
            local += Self.le16(0) + Self.le16(0x21) + Self.le32(crc) + Self.le32(size) + Self.le32(size)
            local += Self.le16(UInt16(nameBytes.count)) + Self.le16(0) + Data(nameBytes) + Data(content)
            body += local

            var extra = Data()
            var sizeField = size
            var offsetField = UInt32(offset)
            if zip64 {
                sizeField = 0xFFFF_FFFF
                offsetField = 0xFFFF_FFFF
                extra = Self.le16(1) + Self.le16(24) + Self.le64(UInt64(size)) + Self.le64(UInt64(size)) + Self.le64(offset)
            }
            let mode: UInt32 = directory ? 0o040755 : 0o100644
            let external: UInt32 = host == 3 ? mode << 16 : (directory ? 0x10 : 0x20)
            var entry = Data()
            entry += Self.le32(0x0201_4B50) + Self.le16(UInt16(host) << 8 | 20) + Self.le16(20) + Self.le16(flags)
            entry += Self.le16(0) + Self.le16(0) + Self.le16(0x21) + Self.le32(crc) + Self.le32(sizeField) + Self.le32(sizeField)
            entry += Self.le16(UInt16(nameBytes.count)) + Self.le16(UInt16(extra.count)) + Self.le16(0)
            entry += Self.le16(0) + Self.le16(0) + Self.le32(external) + Self.le32(offsetField)
            entry += Data(nameBytes) + extra
            central += entry
            count += 1
        }

        func finish(zip64: Bool = false, prefix: Data = Data()) -> Data {
            var out = prefix + body
            let directoryOffset = UInt64(body.count)
            out += central
            if zip64 {
                let recordOffset = UInt64(out.count - prefix.count)
                out += Self.le32(0x0606_4B50) + Self.le64(44) + Self.le16(45) + Self.le16(45) + Self.le32(0) + Self.le32(0)
                out += Self.le64(UInt64(count)) + Self.le64(UInt64(count)) + Self.le64(UInt64(central.count)) + Self.le64(directoryOffset)
                out += Self.le32(0x0706_4B50) + Self.le32(0) + Self.le64(recordOffset) + Self.le32(1)
                out += Self.le32(0x0605_4B50) + Self.le16(0) + Self.le16(0) + Self.le16(0xFFFF) + Self.le16(0xFFFF)
                out += Self.le32(0xFFFF_FFFF) + Self.le32(0xFFFF_FFFF) + Self.le16(0)
            } else {
                out += Self.le32(0x0605_4B50) + Self.le16(0) + Self.le16(0) + Self.le16(UInt16(count)) + Self.le16(UInt16(count))
                out += Self.le32(UInt32(central.count)) + Self.le32(UInt32(directoryOffset)) + Self.le16(0)
            }
            return out
        }
    }

    /// 「中文.txt」的 GBK 字节；「资料\中文.txt」（Windows 用反斜杠）。
    private let gbkName: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4, 0x2E, 0x74, 0x78, 0x74]
    private let gbkNested: [UInt8] = [0xD7, 0xCA, 0xC1, 0xCF, 0x5C, 0xD6, 0xD0, 0xCE, 0xC4, 0x2E, 0x74, 0x78, 0x74]

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: 名字

    func testDecodeNames() {
        XCTAssertEqual(ZipDirectoryReader.decodeName(gbkName, utf8Flag: false), "中文.txt")
        XCTAssertEqual(ZipDirectoryReader.decodeName(Array("照片/海边.jpg".utf8), utf8Flag: true), "照片/海边.jpg")
        // Mac / Linux 打的包常常没有 UTF-8 标记，但名字本身是 UTF-8。
        XCTAssertEqual(ZipDirectoryReader.decodeName(Array("素材包/主视觉.png".utf8), utf8Flag: false), "素材包/主视觉.png")
        XCTAssertEqual(ZipDirectoryReader.decodeName(Array("plain.txt".utf8), utf8Flag: false), "plain.txt")
    }

    func testNormalizeAndJunk() {
        XCTAssertEqual(ArchivePathLogic.normalize("./a/b/")?.path, "a/b")
        XCTAssertEqual(ArchivePathLogic.normalize("./a/b/")?.isDirectory, true)
        XCTAssertEqual(ArchivePathLogic.normalize("/abs/file.txt")?.path, "abs/file.txt")
        XCTAssertNil(ArchivePathLogic.normalize("../evil.txt"))
        XCTAssertNil(ArchivePathLogic.normalize("a/../../evil.txt"))
        XCTAssertEqual(ArchivePathLogic.normalize("a\\b.txt", backslashIsSeparator: true)?.path, "a/b.txt")
        XCTAssertEqual(ArchivePathLogic.normalize("a\\b.txt")?.path, "a\\b.txt")
        XCTAssertTrue(ArchivePathLogic.isJunk("__MACOSX/a/._b.png"))
        XCTAssertTrue(ArchivePathLogic.isJunk("a/.DS_Store"))
        XCTAssertTrue(ArchivePathLogic.isJunk("a/._b.png"))
        XCTAssertFalse(ArchivePathLogic.isJunk("a/b.png"))
        XCTAssertEqual(ArchivePathLogic.parent(of: "a/b/c"), "a/b")
        XCTAssertEqual(ArchivePathLogic.parent(of: "c"), "")
        XCTAssertEqual(ArchivePathLogic.breadcrumb("a/b").map(\.path), ["a", "a/b"])
        XCTAssertTrue(ArchivePathLogic.isInside("a/b/c", "a/b"))
        XCTAssertFalse(ArchivePathLogic.isInside("a/bc", "a/b"))
        XCTAssertTrue(ArchivePathLogic.isInside("x", ""))
    }

    func testKinds() {
        XCTAssertEqual(ArchiveKind.kind(forName: "a.ZIP"), .zip)
        XCTAssertEqual(ArchiveKind.kind(forName: "a.tar.gz"), .tar)
        XCTAssertEqual(ArchiveKind.kind(forName: "a.tgz"), .tar)
        XCTAssertEqual(ArchiveKind.kind(forName: "a.7z"), .other)
        XCTAssertNil(ArchiveKind.kind(forName: "a.dmg"))
        XCTAssertEqual(ArchiveKind.badge(forName: "a.tar.gz"), "TAR")
        XCTAssertEqual(ArchiveKind.badge(forName: "a.zip"), "ZIP")
    }

    // MARK: 文件夹树

    func testTreeBuildsImplicitFoldersAndSizes() {
        let entries = [
            ArchiveEntry(path: "素材/字体/a.ttf", isDirectory: false, size: 100, compressedSize: 60),
            ArchiveEntry(path: "素材/图 10.png", isDirectory: false, size: 50, compressedSize: 50),
            ArchiveEntry(path: "素材/图 2.png", isDirectory: false, size: 30, compressedSize: 20),
            ArchiveEntry(path: "素材/空文件夹", isDirectory: true),
            ArchiveEntry(path: "__MACOSX/素材/._图 2.png", isDirectory: false, size: 4),
            ArchiveEntry(path: "素材/.DS_Store", isDirectory: false, size: 4),
        ]
        let tree = ArchiveTree(entries: entries)
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertEqual(tree.totalSize, 180)
        XCTAssertEqual(tree.singleTopLevel, "素材")
        XCTAssertEqual(tree.children(of: "").map(\.name), ["素材"])
        XCTAssertEqual(tree.node(at: "素材")?.size, 180)
        XCTAssertEqual(tree.node(at: "素材")?.compressedSize, 130)
        XCTAssertEqual(tree.node(at: "素材")?.fileCount, 3)
        // 文件夹在前，「图 2」排在「图 10」前面。
        XCTAssertEqual(tree.children(of: "素材").map(\.name), ["空文件夹", "字体", "图 2.png", "图 10.png"].sorted { a, b in
            let dirs = ["空文件夹", "字体"]
            if dirs.contains(a) != dirs.contains(b) { return dirs.contains(a) }
            return a.localizedStandardCompare(b) == .orderedAscending
        })
        XCTAssertTrue(tree.isDirectory("素材/字体"))
        XCTAssertEqual(Set(tree.entries(under: ["素材/字体"]).map(\.path)), ["素材/字体/a.ttf"])
        XCTAssertEqual(tree.entries(under: [""]).count, 4)
    }

    // MARK: zip 目录

    func testParsesHandBuiltZipWithGBKAndUTF8() throws {
        var builder = ZipBuilder()
        builder.add(gbkNested, Array("你好".utf8), host: 0)
        builder.add(Array("照片/海边.jpg".utf8), [1, 2, 3], utf8Flag: true)
        builder.add(Array("照片/".utf8), [], utf8Flag: true, directory: true)
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("中文包.zip")
        try builder.finish().write(to: zip)

        let entries = try ZipDirectoryReader.readEntries(at: zip)
        XCTAssertEqual(entries.map(\.path), ["资料/中文.txt", "照片/海边.jpg", "照片"])
        XCTAssertEqual(entries[0].size, 6)
        XCTAssertEqual(entries[1].size, 3)
        XCTAssertTrue(entries[2].isDirectory)
        XCTAssertEqual(entries[0].modified, ZipDirectoryReader.dosDateTime(date: 0x21, time: 0))
        XCTAssertEqual(entries[1].unixMode.map { $0 & 0o777 }, 0o644)

        // 解压选中的一个文件夹：名字用解出来的中文。
        let staging = dir.appendingPathComponent("out")
        let tree = ArchiveTree(entries: entries)
        try ArchiveIO.extract(zip, entries: tree.entries(under: ["资料"]), all: false, into: staging)
        let text = try String(contentsOf: staging.appendingPathComponent("资料/中文.txt"), encoding: .utf8)
        XCTAssertEqual(text, "你好")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("照片/海边.jpg").path))
    }

    func testDosDate() {
        let date = ZipDirectoryReader.dosDateTime(date: 0x21, time: 0)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(parts.year, 1980)
        XCTAssertEqual(parts.month, 1)
        XCTAssertEqual(parts.day, 1)
        XCTAssertNil(ZipDirectoryReader.dosDateTime(date: 0, time: 0))
    }

    func testParsesZip64() throws {
        var builder = ZipBuilder()
        builder.add(Array("big/a.bin".utf8), Array(repeating: 7, count: 10), utf8Flag: true, zip64: true)
        builder.add(Array("big/b.bin".utf8), Array(repeating: 8, count: 20), utf8Flag: true, zip64: true)
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("z64.zip")
        try builder.finish(zip64: true).write(to: zip)

        let entries = try ZipDirectoryReader.readEntries(at: zip)
        XCTAssertEqual(entries.map(\.path), ["big/a.bin", "big/b.bin"])
        XCTAssertEqual(entries.map(\.size), [10, 20])
        XCTAssertEqual(entries[1].localHeaderOffset, UInt64(30 + 9 + 10))

        let staging = dir.appendingPathComponent("out")
        try ArchiveIO.extract(zip, entries: entries, all: true, into: staging)
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("big/b.bin")), Data(repeating: 8, count: 20))
    }

    func testPrefixedZipStillReads() throws {
        // 自解压包：前面多了一段数据，目录里记的偏移都要往后挪。
        var builder = ZipBuilder()
        builder.add(Array("a.txt".utf8), Array("hello".utf8), utf8Flag: true)
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("sfx.zip")
        try builder.finish(prefix: Data(repeating: 0, count: 100)).write(to: zip)
        let entries = try ZipDirectoryReader.readEntries(at: zip)
        XCTAssertEqual(entries.first?.localHeaderOffset, 100)
        let staging = dir.appendingPathComponent("out")
        try ArchiveIO.extract(zip, entries: entries, all: true, into: staging)
        XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
    }

    func testNotZipThrows() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("fake.zip")
        try Data("not a zip at all, just text".utf8).write(to: file)
        XCTAssertThrowsError(try ZipDirectoryReader.readEntries(at: file))
    }

    func testEncryptedFlag() throws {
        var entry = [UInt8]()
        // 只测目录解析：标志位 bit 0 = 加密。
        var builder = ZipBuilder()
        builder.add(Array("s.txt".utf8), [1], utf8Flag: true)
        entry = [UInt8](builder.central)
        entry[8] |= 0x01
        let parsed = try ZipDirectoryReader.parseCentralDirectory(entry, expectedCount: 1)
        XCTAssertTrue(parsed[0].isEncrypted)
    }

    // MARK: 系统工具打的包（CI 的 macOS 上有 ditto / tar）

    private func makeSampleFolder(_ dir: URL) throws -> URL {
        let src = dir.appendingPathComponent("素材包", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("字体"), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 5000).write(to: src.appendingPathComponent("色值.txt"))
        try Data("ttf".utf8).write(to: src.appendingPathComponent("字体/思源黑体.ttf"))
        return src
    }

    func testDittoZipRoundTrip() throws {
        let dir = try tempDir()
        let src = try makeSampleFolder(dir)
        let zip = dir.appendingPathComponent("素材包.zip")
        try ArchiveIO.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", src.path, zip.path])

        let entries = try ArchiveIO.list(zip)
        let tree = ArchiveTree(entries: entries)
        XCTAssertEqual(tree.singleTopLevel, "素材包")
        XCTAssertEqual(tree.node(at: "素材包/色值.txt")?.size, 5000)
        XCTAssertLessThan(tree.node(at: "素材包/色值.txt")?.compressedSize ?? .max, 5000)   // deflate 压过
        XCTAssertTrue(tree.isDirectory("素材包/字体"))

        let staging = dir.appendingPathComponent("out")
        try ArchiveIO.extract(zip, entries: tree.entries(under: ["素材包/色值.txt"]), all: false, into: staging)
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("素材包/色值.txt")), Data(repeating: 65, count: 5000))

        // 放到目标文件夹：同名自动加 2。
        let dest = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data().write(to: dest.appendingPathComponent("色值.txt"))
        let placed = try ArchivePlacement.place(["素材包/色值.txt"], from: staging, to: dest)
        XCTAssertEqual(placed.map(\.lastPathComponent), ["色值 2.txt"])
    }

    func testTarGzListAndExtract() throws {
        let dir = try tempDir()
        _ = try makeSampleFolder(dir)
        let archive = dir.appendingPathComponent("素材包.tar.gz")
        try ArchiveIO.run("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "-C", dir.path, "素材包"])

        let entries = try ArchiveIO.list(archive)
        let tree = ArchiveTree(entries: entries)
        XCTAssertEqual(tree.node(at: "素材包/色值.txt")?.size, 5000)
        XCTAssertTrue(tree.isDirectory("素材包/字体"))

        let staging = dir.appendingPathComponent("out")
        try ArchiveIO.extract(archive, entries: tree.entries(under: ["素材包/字体"]), all: false, into: staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("素材包/字体/思源黑体.ttf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("素材包/色值.txt").path))
    }

    func testBsdtarListingParse() {
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let names = "./\n./素材/\n./素材/色 值.txt\n./link\n"
        let verbose = """
        drwxr-xr-x  0 me     staff       0 Oct 27 12:00 ./
        drwxr-xr-x  0 me     staff       0 Oct 27 12:00 ./素材/
        -rw-r--r--  0 me     staff    1234 Jan  3  2024 ./素材/色 值.txt
        lrwxr-xr-x  0 me     staff       0 Oct 27 12:00 ./link -> 素材
        """
        let entries = BsdtarListing.parse(names: names, verbose: verbose, now: now)
        XCTAssertEqual(entries.map(\.path), ["素材", "素材/色 值.txt", "link"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].size, 1234)
        XCTAssertEqual(entries[1].rawName, "./素材/色 值.txt")
        let year = Calendar(identifier: .gregorian).component(.year, from: entries[1].modified!)
        XCTAssertEqual(year, 2024)
        XCTAssertTrue(entries[2].isSymlink)
        XCTAssertNil(entries[2].size)
    }

    func testUniquePlacementName() {
        let taken: Set<String> = ["a.png", "a 2.png", "素材"]
        XCTAssertEqual(ArchivePlacement.uniqueName("a.png") { taken.contains($0) }, "a 3.png")
        XCTAssertEqual(ArchivePlacement.uniqueName("素材") { taken.contains($0) }, "素材 2")
        XCTAssertEqual(ArchivePlacement.uniqueName("b.png") { taken.contains($0) }, "b.png")
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }
}
