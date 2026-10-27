import Foundation

/// 主窗口「移动到… / 拷贝到…」进度卡片的纯逻辑：什么时候弹出、进度比例、剩余时间、显示的文字、限流。
/// 同一块盘上的移动是瞬间改名：按项目数算进度；跨盘（或拷贝）要真的搬数据：按字节算。
enum MoveProgressLogic {
    /// 超过这么久还没做完才弹出卡片（一下子就做完的不打扰）。
    static let showDelay: TimeInterval = 0.5

    /// 要不要显示卡片：已经做完的不显示；要搬数据（跨盘 / 拷贝）的马上显示；其余超过 showDelay 才显示。
    static func shouldShow(elapsed: TimeInterval, movesData: Bool, finished: Bool) -> Bool {
        guard !finished else { return false }
        return movesData || elapsed >= showDelay
    }

    /// 进度比例 0…1。按字节时字节总数为 0（都是空文件）就退回按项目数。
    static func fraction(bytesMode: Bool, itemsDone: Int, itemCount: Int, bytesDone: Int64, bytesTotal: Int64) -> Double {
        let value: Double
        if bytesMode, bytesTotal > 0 {
            value = Double(bytesDone) / Double(bytesTotal)
        } else if itemCount > 0 {
            value = Double(itemsDone) / Double(itemCount)
        } else {
            value = 0
        }
        return min(max(value, 0), 1)
    }

    /// 估计还要多少秒：刚开始（不到 2 秒或不到 3%）不估，免得数字乱跳。
    static func remainingSeconds(elapsed: TimeInterval, fraction: Double) -> TimeInterval? {
        guard elapsed >= 2, fraction >= 0.03, fraction < 1 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }

    /// 「约 1 分钟」「不到 1 分钟」「约 2 小时」。
    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "不到 1 分钟") }
        if seconds < 3600 {
            let minutes = Int((seconds / 60).rounded())
            return String(localized: "约 \(max(1, minutes)) 分钟")
        }
        let hours = Int((seconds / 3600).rounded())
        return String(localized: "约 \(max(1, hours)) 小时")
    }

    /// 卡片标题里的目标：外接磁盘上是「磁盘名 / 文件夹名」，磁盘根目录只写磁盘名，启动盘上只写文件夹名。
    static func destinationLabel(folderName: String, volumeName: String?, isVolumeRoot: Bool) -> String {
        guard let volumeName, !volumeName.isEmpty else { return folderName }
        if isVolumeRoot || volumeName == folderName { return volumeName }
        return "\(volumeName) / \(folderName)"
    }

    /// 卡片第二行：按字节「2.1 GB / 5.4 GB · 约 1 分钟 · 当前：xxx」，按项目「37 / 128 项 · 当前：xxx」。
    static func detailText(bytesMode: Bool, itemsDone: Int, itemCount: Int, bytesDone: Int64, bytesTotal: Int64,
                           remaining: TimeInterval?, currentName: String) -> String {
        var parts: [String] = []
        if bytesMode, bytesTotal > 0 {
            parts.append(bytes(min(bytesDone, bytesTotal)) + " / " + bytes(bytesTotal))
        } else {
            parts.append(String(localized: "\(min(itemsDone, itemCount)) / \(itemCount) 项"))
        }
        if let remaining { parts.append(remainingText(remaining)) }
        if !currentName.isEmpty { parts.append(String(localized: "当前：\(currentName)")) }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// 进度回调限流：两次之间至少隔 interval 秒；force（开始、结束）总是放行；一项项的进度和拷贝中的字节进度都被限流（几千个小文件也不会把主线程淹没）。
    struct Throttle {
        let interval: TimeInterval
        private var last: Date?

        init(interval: TimeInterval = 0.1) {
            self.interval = interval
        }

        mutating func shouldEmit(now: Date, force: Bool = false) -> Bool {
            if !force, let last, now.timeIntervalSince(last) < interval { return false }
            last = now
            return true
        }
    }
}
