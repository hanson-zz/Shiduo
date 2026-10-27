import XCTest

/// 性能优化不改结果：加快后的读文件夹、排序和原来的写法逐项比对。
final class PerfEquivalenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoPerfEq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = [
            "a.txt", "A.txt", "b.TXT", "file2.txt", "file10.txt", "file1.txt", "报告.pdf", "年度报告 3.docx",
            "Ａ全角.txt", "IMG_0001.jpg", "IMG_0002.JPG", "截屏2026-01-02 10.00.00.png", "Screenshot 2026-01-01.png",
            "notes.md", "data.csv", "archive.zip", "noext", "song.mp3", "movie.mov", "Ä umlaut.txt", "é.txt", "e.txt",
        ]
        for (i, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: (i * 37) % 500))
            let t = Date().timeIntervalSince1970 - Double((i % 5) * 3600)
            var times = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
            _ = utimes(url.path, &times)
        }
        for i in 0..<300 {
            let url = dir.appendingPathComponent("bulk \(i % 7 == 0 ? "Photo" : "doc") \(i).\(["png", "txt", "jpg", "md"][i % 4])")
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x42, count: i % 9))
        }
        for name in ["文件夹", "Folder", "folder 2", "folder 10"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 原来的写法：不预取属性，逐个 FileItem(url:)。
    private func referenceListing() -> [FileItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir.path), includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { FileItem(url: $0) }
    }

    /// 比对用：类型树只看包含哪些（父类型的先后本来就没有意义）。
    private func fingerprint(_ item: FileItem) -> String {
        [item.path, item.name, String(item.size), item.contentType ?? "-", item.typeTree.sorted().joined(separator: ","),
         String(item.modified?.timeIntervalSince1970 ?? -1), String(item.created?.timeIntervalSince1970 ?? -1),
         String(item.lastUsed?.timeIntervalSince1970 ?? -1), String(item.added?.timeIntervalSince1970 ?? -1),
         item.whereFroms.joined(separator: ","), String(item.isScreenshot), item.bundleID ?? "-", String(item.isDirectory),
         item.quarantineAgent ?? "-"].joined(separator: "|")
    }

    func testListingMatchesReference() {
        let fast = FolderListing.items(atPath: dir.path, showHidden: false)
        let reference = referenceListing()
        XCTAssertEqual(fast.count, reference.count)
        XCTAssertGreaterThan(fast.count, FolderListing.chunk, "要多于一批，才测得到分批并行")
        XCTAssertEqual(fast.map(fingerprint), reference.map(fingerprint))
    }

    func testSmallListingMatchesReference() {
        let urls = Array(((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles])) ?? []).prefix(10))
        XCTAssertEqual(FolderListing.makeItems(urls).map(fingerprint), urls.compactMap { FileItem(url: $0) }.map(fingerprint))
        XCTAssertEqual(FolderListing.makeItems([]).count, 0)
    }

    func testSortMatchesComparators() {
        var list = referenceListing()
        // 再加几个日期、大小、名字一样的，检查相等时保持原来的先后。
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<6 {
            list.append(FileItem(path: "/tmp/dup\(i)", name: i % 2 == 0 ? "same.txt" : "Same.txt", size: 42,
                                 contentType: "public.plain-text", typeTree: ["public.plain-text"], modified: same,
                                 created: nil, lastUsed: nil, added: nil, whereFroms: [], isScreenshot: false,
                                 bundleID: nil, isDirectory: false))
        }
        list.append(FileItem(path: "/tmp/empty", name: "", size: 0, contentType: nil, typeTree: [], modified: nil,
                             created: nil, lastUsed: nil, added: nil, whereFroms: [], isScreenshot: false,
                             bundleID: nil, isDirectory: false))
        list.shuffle()
        for key in FileSortKey.allCases {
            for ascending in [true, false] {
                let fast = key.sort(list, ascending: ascending).map(\.path)
                let reference = list.sorted(using: key.comparators(ascending: ascending)).map(\.path)
                XCTAssertEqual(fast, reference, "\(key.rawValue) ascending=\(ascending)")
            }
        }
    }

    func testMergeMatchesComparators() {
        let list = referenceListing().shuffled()
        let split = list.count * 2 / 3
        let head = Array(list[..<split]), tail = Array(list[split...])
        for key in FileSortKey.allCases {
            for ascending in [true, false] {
                let order = key.comparators(ascending: ascending)
                let sortedHead = head.sorted(using: order)
                let reference = SortMerge.merge(sortedHead, tail.sorted(using: order)) { a, b in
                    for comparator in order {
                        switch comparator.compare(a, b) {
                        case .orderedAscending: return true
                        case .orderedDescending: return false
                        case .orderedSame: continue
                        }
                    }
                    return false
                }
                let fast = key.merge(sorted: sortedHead, appended: tail, ascending: ascending)
                XCTAssertEqual(fast.map(\.path), reference.map(\.path), "\(key.rawValue) ascending=\(ascending)")
            }
        }
    }

    func testSizeSortMatchesOldImplementation() {
        let list = referenceListing().shuffled()
        let size: (FileItem) -> Int64? = { item in
            item.isDirectory ? (item.name.count % 2 == 0 ? nil : 7) : (item.size % 3 == 0 ? 42 : item.size)
        }
        for ascending in [true, false] {
            let keyed = list.enumerated().map { (index: $0.offset, item: $0.element, size: size($0.element), name: $0.element.name) }
            let reference = keyed.sorted { a, b in
                switch SizeSortLogic.compare(a.size, a.name, b.size, b.name, ascending: ascending) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.index < b.index
                }
            }.map(\.item.path)
            XCTAssertEqual(SizeSortLogic.sorted(list, ascending: ascending, size: size, name: \.name).map(\.path), reference)
        }
    }

    func testKindTextMemoMatches() {
        var memo: [String: String?] = [:]
        for item in referenceListing() {
            XCTAssertEqual(item.memoizedKindText(&memo), item.kindText, item.name)
        }
    }

    func testNameKeyMatchesLocalizedStandardCompare() {
        let names = ["a", "A", "file2", "file10", "Ａ", "é", "e", "", "报告", "年度", "Z", "z1", "z01"]
        for a in names {
            for b in names {
                XCTAssertEqual(NameKey(a).compare(NameKey(b)), a.localizedStandardCompare(b), "\(a) vs \(b)")
            }
        }
    }
}
