import XCTest

/// 简介里的校验值：分块读文件的结果和一次算完一样、能取消、比对认长度 / 大小写 / 空格。
final class HashLogicTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        try data.write(to: url)
        tempFiles.append(url)
        return url
    }

    func testKnownVectors() {
        let hashes = HashLogic.hash(data: Data("abc".utf8))
        XCTAssertEqual(hashes[.md5], "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(hashes[.sha1], "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hashes[.sha256], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEmptyFile() throws {
        let url = try tempFile(Data())
        let hashes = try HashLogic.hash(url: url)
        XCTAssertEqual(hashes[.md5], "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(hashes[.sha1], "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hashes[.sha256], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testStreamingMatchesOneShotForAnyChunkSize() throws {
        var bytes = [UInt8]()
        for i in 0..<100_003 { bytes.append(UInt8((i * 31 + 7) % 251)) }
        let data = Data(bytes)
        let url = try tempFile(data)
        let expected = HashLogic.hash(data: data)
        for chunk in [1 << 20, 4096, 1000, 7] {
            XCTAssertEqual(try HashLogic.hash(url: url, chunkSize: chunk), expected, "chunk \(chunk)")
        }
    }

    func testProgressReachesTotal() throws {
        let data = Data(repeating: 0x5A, count: 10_000)
        let url = try tempFile(data)
        var calls: [(Int64, Int64)] = []
        _ = try HashLogic.hash(url: url, chunkSize: 3000, progress: { calls.append(($0, $1)) })
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.map(\.0), [3000, 6000, 9000, 10_000])
        XCTAssertTrue(calls.allSatisfy { $0.1 == 10_000 })
    }

    func testCancelStopsEarly() throws {
        let url = try tempFile(Data(repeating: 1, count: 50_000))
        var chunks = 0
        XCTAssertThrowsError(try HashLogic.hash(url: url, chunkSize: 1000, progress: { _, _ in chunks += 1 },
                                                isCancelled: { chunks >= 3 })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(chunks, 3)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try HashLogic.hash(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")))
    }

    func testDetectByLength() {
        XCTAssertEqual(HashAlgorithm.detect(hexLength: 32), .md5)
        XCTAssertEqual(HashAlgorithm.detect(hexLength: 40), .sha1)
        XCTAssertEqual(HashAlgorithm.detect(hexLength: 64), .sha256)
        XCTAssertNil(HashAlgorithm.detect(hexLength: 33))
    }

    func testCompare() {
        let hashes = HashLogic.hash(data: Data("abc".utf8))
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(HashLogic.compare("", with: hashes), .empty)
        XCTAssertEqual(HashLogic.compare("   \n", with: hashes), .empty)
        XCTAssertEqual(HashLogic.compare(sha, with: hashes), .match(.sha256))
        // 大写、前后空格、中间换行都算一致
        XCTAssertEqual(HashLogic.compare("  " + sha.uppercased() + " \n", with: hashes), .match(.sha256))
        XCTAssertEqual(HashLogic.compare(String(sha.prefix(32)) + "\n" + String(sha.suffix(32)), with: hashes), .match(.sha256))
        // 官网常见写法
        XCTAssertEqual(HashLogic.compare("SHA-256: " + sha, with: hashes), .match(.sha256))
        XCTAssertEqual(HashLogic.compare(sha + "  Figma-124.5.dmg", with: hashes), .match(.sha256))
        XCTAssertEqual(HashLogic.compare("900150983CD24FB0D6963F7D28E17F72", with: hashes), .match(.md5))
        XCTAssertEqual(HashLogic.compare("a9993e364706816aba3e25717850c26c9cd0d89d", with: hashes), .match(.sha1))
        // 不一致
        var wrong = Array(sha)
        wrong[10] = wrong[10] == "0" ? "1" : "0"
        XCTAssertEqual(HashLogic.compare(String(wrong), with: hashes), .mismatch(.sha256))
        // 长度不对 / 不是十六进制
        XCTAssertEqual(HashLogic.compare("abc123", with: hashes), .unrecognized)
        XCTAssertEqual(HashLogic.compare("这不是校验值", with: hashes), .unrecognized)
        // 还没算
        XCTAssertEqual(HashLogic.compare(sha, with: [:]), .notComputed(.sha256))
    }

    func testAbbreviated() {
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(HashLogic.abbreviated(sha), "ba7816bf8f01cfea…15ad")
        XCTAssertEqual(HashLogic.abbreviated("abcd"), "abcd")
    }
}
