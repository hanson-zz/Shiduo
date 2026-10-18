import CryptoKit
import Foundation

/// 重复文件「移到废纸篓」前的核对：扫描结果是一次性快照，之后用户可能在访达里动过「保留」的那份。
/// 保留的那份已经不在、大小变了，或者（完全相同的一组）开头的内容和要删的那份对不上了，这一组就不删。
/// 纯逻辑 + 读文件，单元测试直接调用；会读磁盘，不要在主线程大批量调用。
enum DuplicateSafety {
    struct Candidate: Sendable {
        let path: String
        /// 扫描时的大小。
        let size: Int64
    }

    struct Group: Sendable {
        let kept: [Candidate]
        let extras: [Candidate]
        /// 完全相同的一组（要比内容）；相似照片只核对保留的还在、没变。
        let exact: Bool
    }

    /// 这一组现在还能安全地删掉多余的副本吗。
    static func isSafe(_ group: Group, fileManager fm: FileManager = .default) -> Bool {
        guard !group.kept.isEmpty else { return false }
        for kept in group.kept {
            guard let attrs = try? fm.attributesOfItem(atPath: kept.path),
                  (attrs[.type] as? FileAttributeType) != .typeDirectory,
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size == kept.size else { return false }
        }
        guard group.exact, let reference = group.kept.first else { return true }
        // 保留的那份开头 64 KB 的指纹要和每份要删的一样（扫描后谁的内容被改了都能发现）。
        guard let keptHash = headHash(reference.path) else { return false }
        for extra in group.extras where fm.fileExists(atPath: extra.path) {
            guard let hash = headHash(extra.path), hash == keptHash else { return false }
        }
        return true
    }

    /// 文件开头 64 KB 的 SHA-256。
    static func headHash(_ path: String, limit: Int = 65_536) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
