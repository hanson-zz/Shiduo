import Foundation

// 判断「完全磁盘访问权限」有没有真正生效。只依赖 Foundation，单元测试也会编译它。
//
// macOS 没有查询这个权限的 API，只能去碰几处“只有拿到完全磁盘访问权限才能读”的地方：
// - 读得到任何一处 → 已授权；
// - 一处都读不到，且至少有一处明确被拒（EPERM / EACCES）→ 未授权；
// - 全都不存在（ENOENT 等）→ 说不准，按未授权处理。
// 以前只看 ~/Library/Application Support/com.apple.TCC/TCC.db 一个文件，它不在 / 读法不对时就永远显示「未开启」。
// 选这些路径的依据见 work/review-2026-10-22-fda.md（PermissionsKit、FullDiskAccess 等开源库的做法）。

enum FullDiskAccessProbe: Equatable, Sendable {
    /// 打开文件并读 1 个字节。
    case file(String)
    /// 列出目录内容（opendir + readdir）。
    case directory(String)

    var path: String {
        switch self {
        case .file(let p), .directory(let p): return p
        }
    }
}

enum FullDiskAccessProbeOutcome: Equatable, Sendable {
    case granted
    case denied
    /// 路径不存在或别的原因，说明不了问题，跳过。
    case inconclusive
}

enum FullDiskAccessStatus: Equatable, Sendable {
    case granted
    case denied
    case unknown

    var isGranted: Bool { self == .granted }
}

enum FullDiskAccessLogic {
    /// 要探测的地方。先读文件（最便宜、不会弹任何系统提示），再列目录。
    static func probes(home: String) -> [FullDiskAccessProbe] {
        func h(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
        return [
            .file(h("Library/Application Support/com.apple.TCC/TCC.db")),
            .file("/Library/Application Support/com.apple.TCC/TCC.db"),
            .file(h("Library/Safari/Bookmarks.plist")),
            .file(h("Library/Safari/CloudTabs.db")),
            .file(h("Library/Messages/chat.db")),
            .file("/Library/Preferences/com.apple.TimeMachine.plist"),
            .directory(h("Library/Application Support/com.apple.TCC")),
            .directory(h("Library/Safari")),
            .directory(h("Library/Messages")),
            .directory(h("Library/Suggestions")),
            .directory(h("Library/Containers/com.apple.stocks")),
        ]
    }

    /// errno → 单个探测的结论。0 表示成功。
    static func outcome(errno code: Int32) -> FullDiskAccessProbeOutcome {
        switch code {
        case 0: return .granted
        case EPERM, EACCES: return .denied
        default: return .inconclusive
        }
    }

    /// 合并多个探测：任何一个成功就算已授权；否则有明确被拒的算未授权；全都说不准就是 unknown。
    static func combine<S: Sequence>(_ outcomes: S) -> FullDiskAccessStatus where S.Element == FullDiskAccessProbeOutcome {
        var sawDenied = false
        for outcome in outcomes {
            switch outcome {
            case .granted: return .granted
            case .denied: sawDenied = true
            case .inconclusive: break
            }
        }
        return sawDenied ? .denied : .unknown
    }

    /// 真正去碰一下文件系统。
    static func run(_ probe: FullDiskAccessProbe) -> FullDiskAccessProbeOutcome {
        switch probe {
        case .file(let path):
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return outcome(errno: errno) }
            defer { close(fd) }
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            // 能打开但读失败（被拦在读这一步）也看 errno；空文件 n == 0 也算读得到。
            return n >= 0 ? .granted : outcome(errno: errno)
        case .directory(let path):
            guard let dir = opendir(path) else { return outcome(errno: errno) }
            defer { closedir(dir) }
            errno = 0
            if readdir(dir) == nil, errno != 0 { return outcome(errno: errno) }
            return .granted
        }
    }

    /// 按顺序探测，遇到第一个成功就停。
    static func check(home: String = NSHomeDirectory()) -> FullDiskAccessStatus {
        combine(probes(home: home).lazy.map { run($0) })
    }
}
