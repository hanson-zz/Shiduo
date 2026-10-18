import Darwin
import Foundation
import OSLog

private let moveOutLog = Logger(subsystem: "io.github.hansonzz.shiduo", category: "files")

/// 搬家里不依赖界面的部分（单元测试会编译这个文件）。
enum MoveOutLogic {
    enum RemoveOutcome: Equatable {
        /// 原文件删干净了。
        case removed
        /// 原文件一点没动（或完整恢复了），目标副本已撤回。
        case untouched
        /// 原位置删到一半失败，还有残留；目标副本完整保留。
        case leftover
    }

    /// 删除已经拷好、核对过的原文件。
    /// 先在同一目录原子改名成临时名再删：改名失败说明一个文件都没动过，才可以安全地删掉目标副本；
    /// 删到一半失败时绝不删目标副本（那是唯一完整的一份），只把残留改回原名，交给用户处理。
    static func removeSource(_ source: URL, expectedSize: Int64, target: URL) -> RemoveOutcome {
        let fm = FileManager.default
        let temp = source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).shiduo-moving-\(UUID().uuidString.prefix(8))")
        // 第一步：原子改名。失败（比如文件本身被锁定）就是什么都没动过。
        guard rename(source.path, temp.path) == 0 else {
            moveOutLog.error("Move out: cannot rename source before removal, errno \(errno, privacy: .public)")
            try? fm.removeItem(at: target)
            return .untouched
        }
        do {
            try fm.removeItem(at: temp)
            return .removed
        } catch {
            moveOutLog.error("Move out: removing source failed midway: \((error as NSError).code, privacy: .public)")
        }
        // 删到一半失败：把残留改回原名。
        if fm.fileExists(atPath: temp.path), !fm.fileExists(atPath: source.path), rename(temp.path, source.path) != 0 {
            moveOutLog.error("Move out: cannot restore leftover name, errno \(errno, privacy: .public)")
        }
        // 原文件其实一点没少（比如删第一个子项就失败了）：这时才可以撤回拷贝。
        if fm.fileExists(atPath: source.path), logicalSize(source) == expectedSize,
           entryCount(source) == entryCount(target) {
            try? fm.removeItem(at: target)
            return .untouched
        }
        return .leftover
    }

    /// 文件（或文件夹里所有文件）的字节数，用来核对拷贝是否完整。
    static func logicalSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory != true { return Int64(values?.fileSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in e {
                let v = try? file.resourceValues(forKeys: keys)
                if v?.isDirectory != true, v?.isSymbolicLink != true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// 条目数（文件夹递归数；文件算 1 个；不存在为 -1）。和大小一起用来确认原文件一点没少。
    static func entryCount(_ url: URL) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return -1 }
        guard isDir.boolValue else { return 1 }
        var n = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case _ as URL in e { n += 1 }
        }
        return n
    }
}
