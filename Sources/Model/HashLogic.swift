import CryptoKit
import Foundation

/// 简介里「校验值」用到的三种算法。
enum HashAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case md5
    case sha1
    case sha256

    var id: String { rawValue }

    /// 界面上的名字（不翻译）。
    var title: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        }
    }

    /// 十六进制写出来有多少位。
    var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        }
    }

    /// 按长度认出是哪种（32 = MD5，40 = SHA-1，64 = SHA-256）。
    static func detect(hexLength: Int) -> HashAlgorithm? {
        allCases.first { $0.hexLength == hexLength }
    }
}

/// 计算和比对文件校验值（纯逻辑，单元测试覆盖）。
/// 大文件一块一块读（默认每块 1 MB），一遍同时算出三种，可以随时取消，内存占用固定。
enum HashLogic {
    static let defaultChunkSize = 1 << 20

    /// 一遍读完文件，同时算出 MD5 / SHA-1 / SHA-256。
    /// progress(已读字节, 总字节) 每读一块调用一次（在调用者的线程上）；isCancelled 返回 true 时抛出 CancellationError。
    static func hash(url: URL,
                     chunkSize: Int = defaultChunkSize,
                     progress: ((Int64, Int64) -> Void)? = nil,
                     isCancelled: () -> Bool = { false }) throws -> [HashAlgorithm: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var done: Int64 = 0
        let size = max(1, chunkSize)
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: size) }
            guard let chunk, !chunk.isEmpty else { break }
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            done += Int64(chunk.count)
            progress?(done, max(total, done))
        }
        if isCancelled() { throw CancellationError() }
        return [
            .md5: hex(md5.finalize()),
            .sha1: hex(sha1.finalize()),
            .sha256: hex(sha256.finalize()),
        ]
    }

    /// 一次算完一段数据（测试和小数据用）。
    static func hash(data: Data) -> [HashAlgorithm: String] {
        [
            .md5: hex(Insecure.MD5.hash(data: data)),
            .sha1: hex(Insecure.SHA1.hash(data: data)),
            .sha256: hex(SHA256.hash(data: data)),
        ]
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 比对

    enum CompareResult: Equatable {
        /// 还没粘贴。
        case empty
        /// 粘贴的内容里找不到 32 / 40 / 64 位的十六进制。
        case unrecognized
        /// 认出了算法，但还没算出这一种。
        case notComputed(HashAlgorithm)
        case match(HashAlgorithm)
        case mismatch(HashAlgorithm)
    }

    /// 从粘贴的内容里取出校验值：去掉空格换行、不分大小写；
    /// 「SHA-256: ABCD…」「abcd…  文件名」这类也认（取其中最后一段 32 / 40 / 64 位的十六进制）。
    static func extract(_ input: String) -> (value: String, algorithm: HashAlgorithm)? {
        let lowered = input.lowercased()
        let compact = lowered.filter { !$0.isWhitespace }
        if !compact.isEmpty, compact.allSatisfy(\.isHexDigit), let algorithm = HashAlgorithm.detect(hexLength: compact.count) {
            return (compact, algorithm)
        }
        // 按非十六进制字符切开，找长度对得上的一段。
        let tokens = lowered.split { !$0.isHexDigit }.map(String.init)
        for token in tokens.reversed() {
            if let algorithm = HashAlgorithm.detect(hexLength: token.count) { return (token, algorithm) }
        }
        return nil
    }

    static func compare(_ input: String, with hashes: [HashAlgorithm: String]) -> CompareResult {
        if input.allSatisfy(\.isWhitespace) { return .empty }
        guard let (value, algorithm) = extract(input) else { return .unrecognized }
        guard let mine = hashes[algorithm] else { return .notComputed(algorithm) }
        return mine.lowercased() == value ? .match(algorithm) : .mismatch(algorithm)
    }

    /// 「9e107d9d372bb682…6d3e」这种中间省略的写法（简介栏窄，放不下 64 位）。
    static func abbreviated(_ hash: String, head: Int = 16, tail: Int = 4) -> String {
        guard hash.count > head + tail + 1 else { return hash }
        return String(hash.prefix(head)) + "…" + String(hash.suffix(tail))
    }
}
