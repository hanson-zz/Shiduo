import CoreFoundation
import Foundation

// 拾掇 Pro：压缩包浏览。这里是纯逻辑（读 zip 目录、整理成文件夹树、解析系统 tar 的列表），单元测试直接编译。
// zip 的目录（central directory）自己读：支持 ZIP64、UTF-8 标记、Info-ZIP Unicode 路径，
// 以及中文 Windows 打的包里常见的 GBK 文件名（没有 UTF-8 标记、又不是合法 UTF-8 时按 GB 18030 解）。
// tar / tar.gz / 7z / rar 交给系统自带的 /usr/bin/tar（libarchive）列出和解压。全部只读，不改压缩包。

/// 压缩包是哪一种（按扩展名认）。
enum ArchiveKind: Equatable {
    case zip
    /// tar、tar.gz / tgz、tar.bz2、tar.xz……系统 tar 能读。
    case tar
    /// 7z、rar：系统 tar（libarchive）大多能读，读不了时给出说明。
    case other

    /// 胶囊里显示的格式名（ZIP、TAR、7Z、RAR）。
    static func badge(forName name: String) -> String {
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(ext) { return "TAR" }
        return (name as NSString).pathExtension.uppercased()
    }

    static func kind(forName name: String) -> ArchiveKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        for ext in [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"] where lower.hasSuffix(ext) {
            return .tar
        }
        if lower.hasSuffix(".7z") || lower.hasSuffix(".rar") { return .other }
        return nil
    }

    static func isBrowsable(name: String) -> Bool { kind(forName: name) != nil }
}

/// 压缩包里的一项（文件或文件夹）。
struct ArchiveEntry: Hashable {
    /// 规范化后的路径「a/b/c.txt」：不带开头的「/」「./」，文件夹不带结尾的「/」。
    var path: String
    var isDirectory: Bool
    /// 解压后大小；不知道时为 nil（系统 tar 列表里没读到）。
    var size: Int64?
    /// 压缩后大小（只有 zip 知道）。
    var compressedSize: Int64?
    var modified: Date?
    var isEncrypted = false
    var isSymlink = false
    /// zip：压缩方式（0 不压缩、8 deflate）和本地文件头的位置。
    var method: UInt16 = 0
    var localHeaderOffset: UInt64 = 0
    /// Unix 权限位（zip 里由 Unix 打包时才有）。
    var unixMode: UInt16? = nil
    /// 系统 tar 列出的原始名字（解压时按它点名）。
    var rawName: String? = nil

    var name: String { (path as NSString).lastPathComponent }
}

/// 压缩包里的路径：规范化、过滤 macOS 打包时夹带的垃圾文件。
enum ArchivePathLogic {
    /// 「./a\\b/」→「a/b」（文件夹）。有「..」的（解压会跑到外面去）返回 nil，不显示也不解压。
    /// backslashIsSeparator：Windows 打的包里有的用「\」当分隔符。
    static func normalize(_ raw: String, backslashIsSeparator: Bool = false) -> (path: String, isDirectory: Bool)? {
        let text = backslashIsSeparator ? raw.replacingOccurrences(of: "\\", with: "/") : raw
        let isDirectory = text.hasSuffix("/")
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return (parts.joined(separator: "/"), isDirectory)
    }

    /// 压缩包里的符号链接指向的位置还在压缩包里面吗（只按字面算：从链接所在的文件夹出发，一层层走 destination，
    /// 「..」退到根目录外面、或者是绝对路径就算跑出去了）。跑出去的链接不建：不然后面一项「链接/文件」
    /// 会顺着链接写到解压文件夹外面（经典的 zip-slip）。
    static func symlinkStaysInside(entryPath: String, destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("/"), !destination.contains("\0") else { return false }
        var stack = entryPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !stack.isEmpty else { return false }
        stack.removeLast()  // 链接自己的名字
        for part in destination.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !stack.isEmpty else { return false }
                stack.removeLast()
            } else {
                stack.append(String(part))
            }
        }
        return true
    }

    /// 访达压缩时夹带的「__MACOSX」、「._xxx」资源分支和 .DS_Store：不显示。
    static func isJunk(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.first == "__MACOSX" { return true }
        guard let last = parts.last else { return true }
        return last == ".DS_Store" || last.hasPrefix("._")
    }

    /// 上一层文件夹（根目录是 ""）。
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// 面包屑：「a/b/c」→ [("a","a"), ("b","a/b"), ("c","a/b/c")]。
    static func breadcrumb(_ path: String) -> [(name: String, path: String)] {
        var result: [(name: String, path: String)] = []
        var current = ""
        for part in path.split(separator: "/") {
            current = current.isEmpty ? String(part) : current + "/" + part
            result.append((String(part), current))
        }
        return result
    }

    /// path 在 dir 里（或就是 dir）。dir 为 "" 表示根目录。
    static func isInside(_ path: String, _ dir: String) -> Bool {
        dir.isEmpty || path == dir || path.hasPrefix(dir + "/")
    }
}

// MARK: - 文件夹树

/// 浏览时的一行：文件，或文件夹（大小是里面所有文件加起来）。
struct ArchiveNode: Identifiable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var compressedSize: Int64?
    var modified: Date?
    var isEncrypted = false
    /// 文件夹里一共有多少个文件（含子文件夹里的）。
    var fileCount = 0
    var id: String { path }
}

/// 把压缩包的条目整理成可以一层层点进去的文件夹树（没有单独记文件夹的包也能补出文件夹）。
struct ArchiveTree {
    private(set) var entries: [ArchiveEntry] = []
    private var nodes: [String: ArchiveNode] = [:]
    private var children: [String: [String]] = [:]
    private(set) var fileCount = 0
    /// 解压后一共多大（不知道大小的条目不算）。
    private(set) var totalSize: Int64 = 0
    private(set) var hasUnknownSizes = false

    init(entries raw: [ArchiveEntry]) {
        var seen = Set<String>()
        var list: [ArchiveEntry] = []
        for entry in raw where !ArchivePathLogic.isJunk(entry.path) {
            // 同一路径出现两次（追加过的 zip）：留后一个。
            if seen.contains(entry.path) {
                list.removeAll { $0.path == entry.path }
            }
            seen.insert(entry.path)
            list.append(entry)
        }
        entries = list
        for entry in list {
            addAncestors(of: entry.path)
            var node = nodes[entry.path] ?? ArchiveNode(path: entry.path, name: entry.name, isDirectory: entry.isDirectory)
            node.isDirectory = entry.isDirectory || node.isDirectory
            node.modified = entry.modified ?? node.modified
            if !node.isDirectory {
                node.size = entry.size
                node.compressedSize = entry.compressedSize
                node.isEncrypted = entry.isEncrypted
                fileCount += 1
                if let size = entry.size { totalSize += size } else { hasUnknownSizes = true }
                // 文件大小加到每一层上级文件夹里。
                var dir = ArchivePathLogic.parent(of: entry.path)
                while !dir.isEmpty {
                    if var folder = nodes[dir] {
                        folder.fileCount += 1
                        if let size = entry.size { folder.size = (folder.size ?? 0) + size }
                        if let packed = entry.compressedSize { folder.compressedSize = (folder.compressedSize ?? 0) + packed }
                        nodes[dir] = folder
                    }
                    dir = ArchivePathLogic.parent(of: dir)
                }
            }
            if nodes[entry.path] == nil { link(entry.path) }
            nodes[entry.path] = node
        }
    }

    private mutating func link(_ path: String) {
        children[ArchivePathLogic.parent(of: path), default: []].append(path)
    }

    private mutating func addAncestors(of path: String) {
        var chain: [String] = []
        var dir = ArchivePathLogic.parent(of: path)
        while !dir.isEmpty, nodes[dir] == nil {
            chain.append(dir)
            dir = ArchivePathLogic.parent(of: dir)
        }
        for dir in chain.reversed() {
            nodes[dir] = ArchiveNode(path: dir, name: (dir as NSString).lastPathComponent, isDirectory: true)
            link(dir)
        }
    }

    func node(at path: String) -> ArchiveNode? { nodes[path] }

    /// 一层里的内容：文件夹在前，再按名字（「图 2」排在「图 10」前面）。
    func children(of dir: String) -> [ArchiveNode] {
        (children[dir] ?? []).compactMap { nodes[$0] }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 这个文件夹在树里（根目录 "" 也算）。
    func isDirectory(_ path: String) -> Bool { path.isEmpty || nodes[path]?.isDirectory == true }

    /// 选中的这些（文件或文件夹）展开成要解压的文件条目（文件夹里所有文件，含空文件夹本身）。
    func entries(under paths: [String]) -> [ArchiveEntry] {
        if paths.contains("") { return entries }
        return entries.filter { entry in paths.contains { ArchivePathLogic.isInside(entry.path, $0) } }
    }

    /// 顶层只有一个项目时它的路径（「全部解压」直接放它，不再套一层文件夹）。
    var singleTopLevel: String? {
        let top = children[""] ?? []
        return top.count == 1 ? top.first : nil
    }
}

// MARK: - zip 目录

enum ZipReadError: Error, Equatable {
    case notZip
    case truncated
    case tooLarge
}

/// 读 zip 的 central directory（只读文件尾部和目录，不读文件内容，几万个文件的包也是一瞬间）。
enum ZipDirectoryReader {
    static let eocdSignature: UInt32 = 0x0605_4B50
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    static let zip64EOCDSignature: UInt32 = 0x0606_4B50
    static let centralSignature: UInt32 = 0x0201_4B50
    static let localSignature: UInt32 = 0x0403_4B50

    /// 读一个 zip 文件的目录。
    static func readEntries(at url: URL) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipReadError.notZip }
        // 文件尾：最长 65535 字节的注释 + 22 字节的目录结尾 + 20 字节的 ZIP64 定位。
        let tailLength = min(fileSize, 65_535 + 22 + 20)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard let end = try locateDirectory(tail: tail, tailOffset: fileSize - tailLength, read: { offset, count in
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }) else { throw ZipReadError.notZip }
        guard end.size <= 512 * 1024 * 1024 else { throw ZipReadError.tooLarge }
        var start = end.offset
        // 自解压包 / 前面多了数据：目录的实际位置 = 目录结尾的位置 - 目录大小。
        var shift: Int64 = 0
        if let actual = end.actualStart, actual != start {
            try handle.seek(toOffset: start)
            let probe = [UInt8](try handle.read(upToCount: 4) ?? Data())
            if probe.count < 4 || ByteReader(probe).u32(0) != centralSignature {
                shift = Int64(actual) - Int64(start)
                start = actual
            }
        }
        try handle.seek(toOffset: start)
        let directory = [UInt8](try handle.read(upToCount: Int(end.size)) ?? Data())
        guard directory.count == Int(end.size) else { throw ZipReadError.truncated }
        var entries = try parseCentralDirectory(directory, expectedCount: end.count)
        if shift != 0 {
            for i in entries.indices { entries[i].localHeaderOffset = UInt64(Int64(entries[i].localHeaderOffset) + shift) }
        }
        return entries
    }

    struct DirectoryLocation: Equatable {
        var offset: UInt64
        var size: UInt64
        var count: UInt64
        /// 按目录结尾的位置推算出的目录开头（只用于普通 zip，判断前面是否多了数据）。
        var actualStart: UInt64?
    }

    /// 从文件尾找目录结尾（EOCD），需要时再读 ZIP64 的目录结尾。
    static func locateDirectory(tail: [UInt8], tailOffset: UInt64,
                                read: (UInt64, Int) throws -> [UInt8]) throws -> DirectoryLocation? {
        guard tail.count >= 22 else { return nil }
        var position: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                // 注释长度对得上才算（避免文件内容里碰巧有这四个字节）。
                let commentLength = Int(ByteReader(tail).u16(i + 20))
                if i + 22 + commentLength <= tail.count { position = i; break }
            }
            i -= 1
        }
        guard let p = position else { return nil }
        let r = ByteReader(tail)
        var count = UInt64(r.u16(p + 10))
        var size = UInt64(r.u32(p + 12))
        var offset = UInt64(r.u32(p + 16))
        let eocdAbsolute = tailOffset + UInt64(p)
        // ZIP64：定位器紧挨在目录结尾前面。
        if p >= 20, r.u32(p - 20) == zip64LocatorSignature {
            let zip64Offset = r.u64(p - 20 + 8)
            let record = try read(zip64Offset, 56)
            if record.count >= 56, ByteReader(record).u32(0) == zip64EOCDSignature {
                let z = ByteReader(record)
                count = z.u64(32)
                size = z.u64(40)
                offset = z.u64(48)
                return DirectoryLocation(offset: offset, size: size, count: count, actualStart: nil)
            }
        }
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            throw ZipReadError.truncated
        }
        let actual = eocdAbsolute >= size ? eocdAbsolute - size : nil
        return DirectoryLocation(offset: offset, size: size, count: count, actualStart: actual)
    }

    /// 解析目录里一条条的文件头。
    static func parseCentralDirectory(_ bytes: [UInt8], expectedCount: UInt64 = 0) throws -> [ArchiveEntry] {
        let r = ByteReader(bytes)
        var entries: [ArchiveEntry] = []
        var i = 0
        while i + 46 <= bytes.count, r.u32(i) == centralSignature {
            let madeBy = r.u16(i + 4)
            let flags = r.u16(i + 8)
            let method = r.u16(i + 10)
            let dosTime = r.u16(i + 12)
            let dosDate = r.u16(i + 14)
            var compressed = UInt64(r.u32(i + 20))
            var uncompressed = UInt64(r.u32(i + 24))
            let nameLength = Int(r.u16(i + 28))
            let extraLength = Int(r.u16(i + 30))
            let commentLength = Int(r.u16(i + 32))
            let external = r.u32(i + 38)
            var localOffset = UInt64(r.u32(i + 42))
            let nameStart = i + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= bytes.count else { throw ZipReadError.truncated }
            let nameBytes = Array(bytes[nameStart..<extraStart])
            var name = decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)
            var mtime: Date?

            // 扩展字段：ZIP64 大小 / 偏移、Info-ZIP Unicode 路径、扩展时间戳。
            var e = extraStart
            let extraEnd = extraStart + extraLength
            while e + 4 <= extraEnd {
                let id = r.u16(e)
                let length = Int(r.u16(e + 2))
                let data = e + 4
                guard data + length <= extraEnd else { break }
                switch id {
                case 0x0001:
                    var f = data
                    if uncompressed == 0xFFFF_FFFF, f + 8 <= data + length { uncompressed = r.u64(f); f += 8 }
                    if compressed == 0xFFFF_FFFF, f + 8 <= data + length { compressed = r.u64(f); f += 8 }
                    if localOffset == 0xFFFF_FFFF, f + 8 <= data + length { localOffset = r.u64(f); f += 8 }
                case 0x7075:
                    // 版本 1 + 原名字的 CRC32 + UTF-8 名字：CRC 对得上才用（原名字被别的工具改过就不用）。
                    if length > 5, bytes[data] == 1, r.u32(data + 1) == CRC32.checksum(nameBytes),
                       let unicode = String(bytes: bytes[(data + 5)..<(data + length)], encoding: .utf8) {
                        name = unicode
                    }
                case 0x5455:
                    // 扩展时间戳：标志位 1 = 有修改时间（UTC 秒数）。
                    if length >= 5, bytes[data] & 1 != 0 {
                        mtime = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: r.u32(data + 1))))
                    }
                default:
                    break
                }
                e = data + length
            }

            // 打包的系统：0 = MS-DOS、11 = NTFS、14 = VFAT（Windows 的包有时用「\」当分隔符）；3 = Unix（有权限位）。
            let host = madeBy >> 8
            let windows = host == 0 || host == 11 || host == 14
            let mode: UInt16? = host == 3 ? UInt16(truncatingIfNeeded: external >> 16) : nil
            let isLink = mode.map { $0 & 0o170000 == 0o120000 } ?? false
            let dosDirectory = external & 0x10 != 0
            if let normalized = ArchivePathLogic.normalize(name, backslashIsSeparator: windows) {
                let isDirectory = normalized.isDirectory || (dosDirectory && uncompressed == 0)
                    || (mode.map { $0 & 0o170000 == 0o040000 } ?? false)
                entries.append(ArchiveEntry(
                    path: normalized.path, isDirectory: isDirectory,
                    size: isDirectory ? nil : Int64(clamping: uncompressed),
                    compressedSize: isDirectory ? nil : Int64(clamping: compressed),
                    modified: mtime ?? dosDateTime(date: dosDate, time: dosTime),
                    isEncrypted: flags & 0x0001 != 0, isSymlink: isLink,
                    method: method, localHeaderOffset: localOffset, unixMode: mode))
            }
            i = next
        }
        if entries.isEmpty, expectedCount > 0 { throw ZipReadError.truncated }
        return entries
    }

    /// 文件名：有 UTF-8 标记按 UTF-8；纯 ASCII 直接用；本身是合法 UTF-8（Mac / Linux 打的包常常不打标记）按 UTF-8；
    /// 否则按 GB 18030（兼容 GBK / GB2312，中文 Windows 打的包）；再不行按 DOS 的 CP437。
    static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        if utf8Flag, let text = String(bytes: bytes, encoding: .utf8) { return text }
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(bytes: bytes, encoding: gb) { return text }
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        return String(bytes: bytes, encoding: dos) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// DOS 日期时间（本地时间，2 秒精度）。全 0 时为 nil。
    static func dosDateTime(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var components = DateComponents()
        components.year = 1980 + Int(date >> 9)
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: components)
    }

    /// 本地文件头后面才是文件内容：返回内容开始的位置需要跳过的长度（30 + 名字 + 扩展字段）。
    static func localHeaderLength(_ header: [UInt8]) -> Int? {
        guard header.count >= 30, ByteReader(header).u32(0) == localSignature else { return nil }
        let r = ByteReader(header)
        return 30 + Int(r.u16(26)) + Int(r.u16(28))
    }
}

/// 小端序读数（越界时读 0，调用前都已检查长度）。
struct ByteReader {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func u16(_ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }

    func u64(_ i: Int) -> UInt64 {
        UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
    }
}

/// CRC32（zip 用的那种），只用来核对 Unicode 路径字段。
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - 系统 tar 的列表

/// /usr/bin/tar（libarchive）列出来的内容：-tf 给出原始名字（准），-tvf 同样顺序多出权限、大小、日期。
/// 两份按行对上，-tvf 那行以名字结尾才取大小，取不到就不显示大小（不会因为解析不了漏掉文件）。
enum BsdtarListing {
    static func parse(names: String, verbose: String, now: Date = Date()) -> [ArchiveEntry] {
        let nameLines = names.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let verboseLines = verbose.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var result: [ArchiveEntry] = []
        for (index, raw) in nameLines.enumerated() {
            let line = index < verboseLines.count ? verboseLines[index] : ""
            let perms = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let isDirectoryByMode = perms.hasPrefix("d")
            let isLink = perms.hasPrefix("l")
            guard let normalized = ArchivePathLogic.normalize(raw) else { continue }
            let isDirectory = normalized.isDirectory || isDirectoryByMode
            var size: Int64?
            var date: Date?
            if !line.isEmpty, line.hasSuffix(raw) {
                let prefix = line.dropLast(raw.count)
                let tokens = prefix.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                // -rw-r--r--  0 user staff  1234 Oct 27 12:00 name
                if tokens.count >= 8 {
                    size = Int64(tokens[4])
                    date = parseDate(month: tokens[5], day: tokens[6], timeOrYear: tokens[7], now: now)
                }
            }
            result.append(ArchiveEntry(path: normalized.path, isDirectory: isDirectory,
                                       size: isDirectory ? nil : size, compressedSize: nil, modified: date,
                                       isSymlink: isLink, rawName: raw))
        }
        return result
    }

    /// 「Oct 27 12:00」（今年，算出来在未来就是去年）或「Oct 27 2024」。
    static func parseDate(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let m = months.firstIndex(of: month), let d = Int(day) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.month = m + 1
        components.day = d
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let min = Int(parts[1]) else { return nil }
            components.hour = h
            components.minute = min
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year! -= 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }
}
