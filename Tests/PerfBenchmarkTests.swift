import XCTest
import AppKit
import CoreServices
import ImageIO
import UniformTypeIdentifiers

/// 性能实测：在临时文件夹里生成 1,000 / 10,000 / 50,000 个文件（小图片、文本、嵌套文件夹），
/// 给真实的非界面代码计时：读文件夹列表、排序、文件夹大小、第一屏缩略图、搜索过滤。
/// 只把结果打到日志里（以「PERF|」开头的行），不设时间门槛，不会因为 CI 机器忙而失败。
/// GitHub 的 macOS 机器上的数字只能互相比较，真实 Mac 上会不一样。
final class PerfBenchmarkTests: XCTestCase {
    // MARK: 测试数据

    static let counts = [1_000, 10_000, 50_000]
    private static var root: URL?
    private static var fixtures: [Int: URL] = [:]
    private static var listed: [Int: [FileItem]] = [:]
    private static var rows: [String] = []

    override class func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiduoPerf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
        let png = Self.imageData(type: UTType.png, side: 16)
        let jpg = Self.imageData(type: UTType.jpeg, side: 16)
        for n in counts {
            let start = DispatchTime.now().uptimeNanoseconds
            let folder = base.appendingPathComponent("n\(n)", isDirectory: true)
            generate(at: folder, count: n, png: png, jpg: jpg)
            fixtures[n] = folder
            print("PERF|setup|\(n)|generate|\(String(format: "%.0f", ms(since: start)))ms")
        }
    }

    override class func tearDown() {
        print("PERF|==== 汇总（毫秒；中位数 / 最快 / 次数）====")
        for row in rows { print(row) }
        print("PERF|==== 汇总结束 ====")
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// 一个小图片的字节（生成一次，写很多份）。
    private static func imageData(type: UTType, side: Int, seed: Int = 0) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = CGFloat(seed % 12) / 12
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(NSColor(hue: 1 - hue, saturation: 0.7, brightness: 0.5, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// 文件夹结构：80% 的文件直接放在里面，另外 N/100 个子文件夹各放 20 个（一半在更深一层）。
    private static func generate(at folder: URL, count: Int, png: Data, jpg: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let direct = count * 8 / 10
        let subfolders = max(1, count / 100)
        let perSub = (count - direct) / subfolders
        let text = Data(repeating: 0x61, count: 4096)
        let now = Date().timeIntervalSince1970
        func write(_ dir: URL, _ i: Int) {
            let name: String
            let data: Data
            switch i % 8 {
            case 0: name = "IMG_\(i).jpg"; data = jpg
            case 1: name = "截屏2026-0\(i % 9 + 1)-1\(i % 9) 10.\(i % 60).00 \(i).png"; data = png
            case 2: name = "年度报告 \(i).txt"; data = text.prefix(64 + i % 4000)
            case 3: name = "notes \(i).md"; data = text.prefix(32 + i % 900)
            case 4: name = "Photo \(i).png"; data = png
            case 5: name = "file\(i).txt"; data = text.prefix(i % 2000)
            case 6: name = "设计稿-v\(i).jpg"; data = jpg
            default: name = "Data_\(i).csv"; data = text.prefix(100 + i % 3000)
            }
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: data)
            // 日期错开，按日期排序才像样。
            let t = now - Double((i * 7919) % 3_000_000)
            var times = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
            _ = utimes(url.path, &times)
        }
        for i in 0..<direct { write(folder, i) }
        var index = direct
        for s in 0..<subfolders {
            let sub = folder.appendingPathComponent("文件夹 \(s)", isDirectory: true)
            let deep = sub.appendingPathComponent("更深 \(s)", isDirectory: true)
            try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
            for k in 0..<perSub {
                write(k % 2 == 0 ? sub : deep, index)
                index += 1
            }
        }
    }

    // MARK: 计时

    private static func ms(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }

    /// 跑 runs 次，记下中位数和最快的一次。
    @discardableResult
    private func measureMs(_ section: String, _ n: Int, _ variant: String, runs: Int = 3, note: String = "",
                           _ body: () -> Void) -> Double {
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            autoreleasepool { body() }
            times.append(Self.ms(since: start))
        }
        times.sort()
        let median = times[times.count / 2]
        record(section, n, variant, median: median, min: times[0], runs: runs, note: note)
        return median
    }

    private func record(_ section: String, _ n: Int, _ variant: String, median: Double, min: Double, runs: Int,
                        note: String = "") {
        let row = "PERF|\(section)|\(n)|\(variant)|median=\(String(format: "%.1f", median))ms|min=\(String(format: "%.1f", min))ms|runs=\(runs)"
            + (note.isEmpty ? "" : "|\(note)")
        print(row)
        Self.rows.append(row)
    }

    private func folder(_ n: Int) throws -> URL {
        try XCTUnwrap(Self.fixtures[n], "测试数据没生成出来")
    }

    private func items(_ n: Int) throws -> [FileItem] {
        if let cached = Self.listed[n] { return cached }
        let list = FolderListing.items(atPath: try folder(n).path, showHidden: false)
        Self.listed[n] = list
        return list
    }

    // MARK: 1. 读文件夹列表（浏览器打开文件夹走的路径）

    func testPerf1Listing() throws {
        for n in Self.counts {
            let path = try folder(n).path
            var count = 0
            measureMs("listing", n, "FolderListing.items", runs: n >= 50_000 ? 2 : 3) {
                count = FolderListing.items(atPath: path, showHidden: false).count
            }
            XCTAssertGreaterThan(count, 0)
            print("PERF|listing|\(n)|entries=\(count)")
            // 原来的写法（不预取属性、单线程逐个 FileItem(url:)），同一台机器上对照。50,000 太慢，只看第一次 CI 的基线。
            if n <= 10_000 {
                measureMs("listing", n, "reference(old)", runs: n >= 10_000 ? 1 : 3) {
                    let urls = (try? FileManager.default.contentsOfDirectory(
                        at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    _ = urls.compactMap { FileItem(url: $0) }
                }
            }
        }
    }

    /// 读一个项目的各步分别花多少（10,000 的那份）：找出慢在哪。
    func testPerf2ListingBreakdown() throws {
        let n = 10_000
        let url = try folder(n)
        let keys: [URLResourceKey] = [
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentTypeKey, .isDirectoryKey, .addedToDirectoryDateKey, .isPackageKey,
        ]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        XCTAssertFalse(urls.isEmpty)
        measureMs("breakdown", n, "contentsOfDirectory(keys:nil)") {
            _ = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }
        measureMs("breakdown", n, "contentsOfDirectory(keys:7)") {
            _ = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        measureMs("breakdown", n, "resourceValues(7 keys, fresh URL)") {
            for u in urls { _ = try? URL(fileURLWithPath: u.path).resourceValues(forKeys: Set(keys)) }
        }
        measureMs("breakdown", n, "UTType.supertypes") {
            for u in urls {
                if let type = UTType(filenameExtension: u.pathExtension) {
                    _ = [type.identifier] + type.supertypes.map(\.identifier)
                }
            }
        }
        measureMs("breakdown", n, "MDItemCreate+4 attrs") {
            for u in urls {
                if let md = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL) {
                    _ = MDItemCopyAttribute(md, "kMDItemLastUsedDate" as CFString)
                    _ = MDItemCopyAttribute(md, "kMDItemWhereFroms" as CFString)
                    _ = MDItemCopyAttribute(md, "kMDItemIsScreenCapture" as CFString)
                    _ = MDItemCopyAttribute(md, "kMDItemCFBundleIdentifier" as CFString)
                }
            }
        }
        measureMs("breakdown", n, "MDItemCreate only") {
            for u in urls { _ = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL) }
        }
        let names = ["kMDItemLastUsedDate", "kMDItemWhereFroms", "kMDItemIsScreenCapture", "kMDItemCFBundleIdentifier"] as CFArray
        measureMs("breakdown", n, "MDItemCreate+CopyAttributes(1 call)") {
            for u in urls {
                if let md = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL) { _ = MDItemCopyAttributes(md, names) }
            }
        }
        measureMs("breakdown", n, "MDItemCreate+CopyAttributes parallel") {
            DispatchQueue.concurrentPerform(iterations: (urls.count + 127) / 128) { b in
                for i in (b * 128)..<min(urls.count, (b + 1) * 128) {
                    if let md = MDItemCreateWithURL(kCFAllocatorDefault, urls[i] as CFURL) { _ = MDItemCopyAttributes(md, names) }
                }
            }
        }
        // 试验：一批 128 个一次问 Spotlight（MDItemsCreateWithURLs + MDItemsCopyAttributes）。
        func batch(_ b: Int) -> Int {
            let slice = Array(urls[(b * 128)..<min(urls.count, (b + 1) * 128)])
            guard let created = MDItemsCreateWithURLs(kCFAllocatorDefault, slice as NSArray as CFArray) as? [AnyObject] else { return 0 }
            let valid = created.filter { !($0 is NSNull) }
            guard !valid.isEmpty else { return 0 }
            let values = MDItemsCopyAttributes(valid as NSArray as CFArray, names) as? [AnyObject] ?? []
            return values.count
        }
        let batches = (urls.count + 127) / 128
        var batchCount = 0
        measureMs("breakdown", n, "MDItems batch(128)") {
            batchCount = 0
            for b in 0..<batches { batchCount += batch(b) }
        }
        measureMs("breakdown", n, "MDItems batch(128) parallel") {
            DispatchQueue.concurrentPerform(iterations: batches) { b in _ = batch(b) }
        }
        print("PERF|breakdown|\(n)|batchValues=\(batchCount)")
        print("PERF|breakdown|\(n)|cpu=\(ProcessInfo.processInfo.activeProcessorCount)")
        measureMs("breakdown", n, "xattr whereFroms+quarantine") {
            for u in urls {
                _ = ExtendedAttributes.whereFroms(atPath: u.path)
                _ = ExtendedAttributes.quarantineAgent(atPath: u.path)
            }
        }
        measureMs("breakdown", n, "ScreenshotNameRules") {
            let folders = ScreenshotFolders.current
            for u in urls {
                _ = ScreenshotNameRules.isScreenshot(name: u.lastPathComponent, typeTree: [], systemFlag: false,
                                                     path: u.path, folders: folders)
            }
        }
        measureMs("breakdown", n, "FileItem(url:) all") {
            for u in urls { _ = FileItem(url: u) }
        }
        measureMs("breakdown", n, "FolderListing.makeItems(no prefetch)") {
            _ = FolderListing.makeItems(urls.map { URL(fileURLWithPath: $0.path) })
        }
    }

    // MARK: 2. 排序（浏览器网格 / 列表）

    func testPerf3Sort() throws {
        for n in Self.counts {
            let list = try items(n)
            for key in FileSortKey.allCases where key != .size {
                for ascending in [key.defaultAscending] {
                    let runs = n >= 50_000 && key == .kind ? 1 : 3
                    measureMs("sort", n, "\(key.rawValue)\(ascending ? "↑" : "↓")", runs: runs) {
                        _ = key.sort(list, ascending: ascending)
                    }
                }
            }
            // 原来的写法：KeyPathComparator，每次比较现取键。种类排序太慢（10,000 个要十几秒），只在 1,000 时对照。
            for key in [FileSortKey.date, .name, .kind] where key != .kind || n <= 1_000 {
                let ascending = key.defaultAscending
                measureMs("sort", n, "\(key.rawValue)\(ascending ? "↑" : "↓")reference(old)", runs: n >= 50_000 ? 1 : 3) {
                    _ = list.sorted(using: key.comparators(ascending: ascending))
                }
            }
            // 按大小：文件夹用后台算好的大小（这里假装一半已经算出来）。
            var known: [String: Int64] = [:]
            for (i, item) in list.enumerated() where item.isDirectory && i % 2 == 0 { known[item.path] = Int64(i * 1000) }
            measureMs("sort", n, "size↓(SizeSortLogic)", runs: 3) {
                _ = SizeSortLogic.sorted(list, ascending: false,
                                         size: { $0.isDirectory ? known[$0.path] : Optional($0.size) }, name: \.name)
            }
            measureMs("sort", n, "size↓reference(old)", runs: n >= 50_000 ? 1 : 3) {
                _ = Self.referenceSizeSort(list, ascending: false,
                                           size: { $0.isDirectory ? known[$0.path] : Optional($0.size) }, name: \.name)
            }
            // 主线程上每次重排后还会做的：比较新旧顺序、生成 URL 列表（给快速查看左右翻页用）。
            let copy = list.map { $0 }
            var same = false
            measureMs("mainThread", n, "[FileItem] == (different buffers)") { same = list == copy }
            XCTAssertTrue(same)
            measureMs("mainThread", n, "map(\\.url)") { _ = list.map(\.url) }
            let urls = list.map(\.url)
            let resorted = FileSortKey.name.sort(list, ascending: true)
            var reused: [URL] = []
            measureMs("mainThread", n, "SortedURLs.make(after resort)") {
                reused = SortedURLs.make(for: resorted, previous: list, previousURLs: urls)
            }
            XCTAssertEqual(reused, resorted.map(\.url))
        }
    }

    /// 原来的 SizeSortLogic.sorted（优化前的写法），对照用。
    private static func referenceSizeSort<T>(_ items: [T], ascending: Bool, size: (T) -> Int64?, name: (T) -> String) -> [T] {
        let keyed = items.enumerated().map { (index: $0.offset, item: $0.element, size: size($0.element), name: name($0.element)) }
        return keyed.sorted { a, b in
            switch SizeSortLogic.compare(a.size, a.name, b.size, b.name, ascending: ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.index < b.index
            }
        }.map(\.item)
    }

    // MARK: 3. 文件夹大小（FolderSizeStore 后台用的 FolderWalker）

    func testPerf4FolderSize() throws {
        for n in Self.counts {
            let url = try folder(n)
            var count = 0
            measureMs("folderSize", n, "FolderWalker.stats", runs: 2) {
                count = FolderWalker.stats(of: url)?.itemCount ?? 0
            }
            XCTAssertGreaterThan(count, 0)
        }
    }

    // MARK: 4. 搜索过滤（文件名包含 + 拼音首字母）

    func testPerf5SearchFilter() throws {
        for n in [10_000, 50_000] {
            let list = try items(n)
            for text in ["报告", "ndbg", "photo", "上周超过5MB的pdf"] {
                var hits = 0
                let filter = {
                    let query = QueryParser().parse(text)
                    let needle = query.text.isEmpty ? text : query.text
                    hits = list.filter { item in
                        item.name.localizedCaseInsensitiveContains(needle)
                            || Pinyin.matches((item.name as NSString).deletingPathExtension, query: needle)
                    }.count
                }
                // 第一次：拼音缓存是冷的；之后是热的。
                let start = DispatchTime.now().uptimeNanoseconds
                filter()
                let cold = Self.ms(since: start)
                record("search", n, "\(text)(cold)", median: cold, min: cold, runs: 1)
                measureMs("search", n, "\(text)(warm)", runs: 3, note: "hits=\(hits)") { filter() }
            }
        }
    }

    // MARK: 5. 第一屏缩略图（约 60 个，QLThumbnailGenerator）

    func testPerf6FirstScreenThumbnails() async throws {
        guard let root = Self.root else { throw XCTSkip("没有测试数据") }
        let dir = root.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<60 {
            let isPNG = i % 2 == 0
            let data = Self.imageData(type: isPNG ? .png : .jpeg, side: 1024, seed: i)
            let url = dir.appendingPathComponent("photo \(i).\(isPNG ? "png" : "jpg")")
            try data.write(to: url)
            urls.append(url)
        }
        for round in 1...2 {
            let service = ThumbnailService()
            let start = DispatchTime.now().uptimeNanoseconds
            // 每个完成的时间（毫秒，从开始算）；没生成出来的是 nil。
            let finished: [Double?] = await withTaskGroup(of: Double?.self) { group in
                for url in urls {
                    group.addTask {
                        let image = await service.thumbnail(for: url, size: 120)
                        return image == nil ? nil : Self.ms(since: start)
                    }
                }
                var out: [Double?] = []
                for await value in group { out.append(value) }
                return out
            }
            let all = Self.ms(since: start)
            let done = finished.compactMap { $0 }
            let ok = done.count
            let firstMs = done.min()
            if ok == 0 {
                print("PERF|thumbnails|60|skip|QLThumbnailGenerator 在这台机器上没生成出缩略图")
                return
            }
            record("thumbnails", 60, "first(round\(round))", median: firstMs ?? all, min: firstMs ?? all, runs: 1)
            record("thumbnails", 60, "all60(round\(round))", median: all, min: all, runs: 1, note: "ok=\(ok)")
            // 同一个实例再取一遍：全部命中缓存。
            let cacheStart = DispatchTime.now().uptimeNanoseconds
            for url in urls { _ = service.cached(for: url, size: 120) }
            let cached = Self.ms(since: cacheStart)
            record("thumbnails", 60, "cachedLookup(round\(round))", median: cached, min: cached, runs: 1)
        }
    }
}
