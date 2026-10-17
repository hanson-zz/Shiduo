import Foundation

/// 拾掇 Pro「文件夹上色」的样式：颜色 + 叠加层 + 叠加层大小。
/// 这个文件只用 Foundation，单元测试直接编译它。
struct FolderIconStyle: Codable, Hashable {
    enum Overlay: Hashable {
        case none
        case symbol(String)
        case emoji(String)
        /// 本地图片的路径。
        case image(String)
    }

    static let scaleRange: ClosedRange<Double> = 0.3...0.7
    static let defaultScale = 0.45

    /// 十六进制 RRGGBB（大写，不带 #）。
    var color: String
    var overlay: Overlay
    /// 叠加层边长占图标边长的比例，0.3–0.7。
    var overlayScale: Double

    init(color: String, overlay: Overlay = .none, overlayScale: Double = FolderIconStyle.defaultScale) {
        self.color = FolderIconStyle.normalizedHex(color) ?? "87B3EB"
        self.overlay = overlay
        self.overlayScale = FolderIconStyle.clampScale(overlayScale)
    }

    static func clampScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultScale }
        return min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// 「#ff8800」「FF8800」都变成「FF8800」；不合法返回 nil。
    static func normalizedHex(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return s
    }

    /// 0–1 的 RGB 分量。
    var rgb: (red: Double, green: Double, blue: Double) {
        let v = Int(color, radix: 16) ?? 0x87B3EB
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    // MARK: Codable（叠加层写成 {"type": "symbol", "value": "star"}，好读也好迁移）

    private enum CodingKeys: String, CodingKey { case color, overlay, overlayScale }
    private enum OverlayKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try c.decode(String.self, forKey: .color)
        let scale = try c.decodeIfPresent(Double.self, forKey: .overlayScale) ?? Self.defaultScale
        var overlay = Overlay.none
        if c.contains(.overlay) {
            let o = try c.nestedContainer(keyedBy: OverlayKeys.self, forKey: .overlay)
            let type = try o.decode(String.self, forKey: .type)
            let value = try o.decodeIfPresent(String.self, forKey: .value) ?? ""
            switch type {
            case "symbol" where !value.isEmpty: overlay = .symbol(value)
            case "emoji" where !value.isEmpty: overlay = .emoji(value)
            case "image" where !value.isEmpty: overlay = .image(value)
            default: overlay = .none
            }
        }
        self.init(color: hex, overlay: overlay, overlayScale: scale)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(overlayScale, forKey: .overlayScale)
        var o = c.nestedContainer(keyedBy: OverlayKeys.self, forKey: .overlay)
        switch overlay {
        case .none: try o.encode("none", forKey: .type)
        case .symbol(let name):
            try o.encode("symbol", forKey: .type)
            try o.encode(name, forKey: .value)
        case .emoji(let text):
            try o.encode("emoji", forKey: .type)
            try o.encode(text, forKey: .value)
        case .image(let path):
            try o.encode("image", forKey: .type)
            try o.encode(path, forKey: .value)
        }
    }
}

/// 一个上过色的文件夹：最后一次用的样式，以及上色之前的原样（用来还原）。
struct FolderIconRecord: Codable, Equatable {
    var style: FolderIconStyle
    /// 第一次上色之前，文件夹是否已经有自定义图标。
    var hadCustomIcon: Bool
    /// 原自定义图标的备份文件名（在 FolderIcons 目录下）；没有就是 nil。
    var backupFile: String?
    var date: Date
}

/// 上色记录 + 最近用过的样式，存成一个 JSON 文件。纯数据逻辑，方便测试。
struct FolderIconLedger: Codable, Equatable {
    static let historyLimit = 20

    /// 文件夹路径 → 记录。
    var folders: [String: FolderIconRecord] = [:]
    /// 最近用过的样式，最新的在最前，不重复，最多 20 个。
    var history: [FolderIconStyle] = []

    /// 把样式放到历史最前面：已有的先拿掉，超过 20 个丢掉最旧的。
    mutating func remember(_ style: FolderIconStyle) {
        history.removeAll { $0 == style }
        history.insert(style, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    /// 记下一次上色。已经上过色的文件夹保留最早的原样信息，这样还原时回到真正的原样。
    mutating func recordApplied(_ style: FolderIconStyle, path: String, hadCustomIcon: Bool, backupFile: String?, date: Date = Date()) {
        if var existing = folders[path] {
            existing.style = style
            existing.date = date
            folders[path] = existing
        } else {
            folders[path] = FolderIconRecord(style: style, hadCustomIcon: hadCustomIcon, backupFile: backupFile, date: date)
        }
    }

    /// 文件夹被移动或重命名：它自己和里面子文件夹的记录都跟着改路径。
    mutating func movePath(_ old: String, to new: String) {
        guard old != new, !old.isEmpty else { return }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        var moved: [String: FolderIconRecord] = [:]
        for (path, record) in folders {
            if path == old {
                moved[new] = record
            } else if path.hasPrefix(prefix) {
                moved[new + "/" + path.dropFirst(prefix.count)] = record
            } else {
                continue
            }
            folders[path] = nil
        }
        folders.merge(moved) { _, incoming in incoming }
    }
}
