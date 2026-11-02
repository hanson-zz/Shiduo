import Foundation

/// 拾掇 Pro「文件夹换装」的样式：颜色（或主题图标 + 色相）+ 叠加层 + 叠加层大小。
/// 这个文件只用 Foundation，单元测试直接编译它。
struct FolderIconStyle: Codable, Hashable {
    enum Overlay: Hashable {
        case none
        case symbol(String)
        case emoji(String)
        /// 本地图片的路径。
        case image(String)
    }

    /// 叠加层的底：贴纸白边（沿字形 / 图片轮廓描一圈白边 + 淡阴影）、白色圆底、什么都不垫。
    enum Backdrop: String, Codable, Hashable, CaseIterable {
        case sticker
        case disc
        /// 不垫底（存成 "none"；不叫 .none，免得和 Optional.none 混淆）。
        case bare = "none"
    }

    /// 叠加层中心点在图标画布里的位置，0…1，原点在左上角（和界面里拖动的坐标一致）。
    struct Point: Codable, Hashable {
        var x: Double
        var y: Double
        init(x: Double, y: Double) {
            self.x = x.isFinite ? min(max(x, 0), 1) : 0.5
            self.y = y.isFinite ? min(max(y, 0), 1) : 0.5
        }

        private enum CodingKeys: String, CodingKey { case x, y }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
        }
    }

    /// 0…1 画布里的一个方框，原点在左上角。
    struct Frame: Equatable {
        var x: Double, y: Double, width: Double, height: Double
        var midX: Double { x + width / 2 }
        var midY: Double { y + height / 2 }
        func contains(_ p: Point) -> Bool { p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height }
    }

    static let scaleRange: ClosedRange<Double> = 0.3...0.7
    static let defaultScale = 0.45
    /// 主题图标的色相调整，单位度。
    static let hueRange: ClosedRange<Double> = -180...180

    /// 十六进制 RRGGBB（大写，不带 #）。
    var color: String
    var overlay: Overlay
    /// 叠加层边长占图标边长的比例，0.3–0.7。
    var overlayScale: Double
    /// 主题图标「分类/名字」（如 animal/cat）；nil 是普通的上色。有主题时不用 color 染色。
    var theme: String?
    /// 主题图标的色相调整（度，-180…180），0 是原样。
    var hue: Double
    /// 叠加层的底。旧版本存的样式没有这个字段：主题图标上是白色圆底，普通上色什么都不垫（解码时照旧，图标不变样）。
    var backdrop: Backdrop
    /// 叠加层中心点（用户拖过的位置）；nil 是默认位置（普通上色在正面中间偏下，主题图标在右下角）。
    var overlayCenter: Point?

    init(color: String, overlay: Overlay = .none, overlayScale: Double = FolderIconStyle.defaultScale,
         theme: String? = nil, hue: Double = 0, backdrop: Backdrop? = nil, overlayCenter: Point? = nil) {
        self.color = FolderIconStyle.normalizedHex(color) ?? "87B3EB"
        self.overlay = overlay
        self.overlayScale = FolderIconStyle.clampScale(overlayScale)
        self.theme = FolderIconStyle.normalizedTheme(theme)
        self.hue = self.theme == nil ? 0 : FolderIconStyle.clampHue(hue)
        self.backdrop = backdrop ?? FolderIconStyle.defaultBackdrop(for: overlay, themed: self.theme != nil)
        self.overlayCenter = overlayCenter
    }

    /// 新建叠加层时默认的底：Emoji、图片用贴纸白边；符号在普通上色上是同色系压印，不垫；在主题图标上垫白色圆底。
    static func defaultBackdrop(for overlay: Overlay, themed: Bool) -> Backdrop {
        switch overlay {
        case .emoji, .image: return .sticker
        case .symbol: return themed ? .disc : .bare
        case .none: return themed ? .disc : .bare
        }
    }

    /// 旧版本存的样式（没有 backdrop 字段）当时的样子：主题图标上是白色圆底，普通上色不垫。
    static func legacyBackdrop(themed: Bool) -> Backdrop { themed ? .disc : .bare }

    // MARK: 叠加层位置（纯计算，坐标都是 0…1，原点左上）

    /// 叠加层边长占画布的比例。主题图标上是小角标，按 0.62 缩小。
    static func overlayLength(scale: Double, themed: Bool) -> Double {
        clampScale(scale) * (themed ? 0.62 : 1)
    }

    /// 默认位置：普通上色在正面中心偏下（离底 42%），主题图标在右下角（离边 7%）。
    static func defaultCenter(scale: Double, themed: Bool) -> Point {
        let length = overlayLength(scale: scale, themed: themed)
        if themed {
            let margin = 0.07
            return Point(x: 1 - margin - length / 2, y: 1 - margin - length / 2)
        }
        return Point(x: 0.5, y: 1 - 0.42)
    }

    /// 叠加层最多伸出画布多少（占自身边长）。中心点始终在画布里，最多露出一小半在外面，不会整个拖没。
    static let maxOverhang = 0.25

    /// 把中心点夹在画布里：每边最多让叠加层伸出 maxOverhang 倍边长。
    static func clampCenter(_ p: Point, length: Double) -> Point {
        let length = length.isFinite ? min(max(length, 0), 1) : 0
        let lo = min(0.5, max(0, length * (0.5 - maxOverhang)))
        let hi = 1 - lo
        return Point(x: min(max(p.x, lo), hi), y: min(max(p.y, lo), hi))
    }

    /// 这个样式实际画叠加层的中心点（自定义位置夹过，或默认位置）。
    func resolvedCenter(themed: Bool) -> Point {
        let length = Self.overlayLength(scale: overlayScale, themed: themed)
        return Self.clampCenter(overlayCenter ?? Self.defaultCenter(scale: overlayScale, themed: themed), length: length)
    }

    /// 叠加层在 0…1 画布里的方框（原点左上）。预览拖动的命中判断和真正渲染都用它。
    func overlayFrame(themed: Bool) -> Frame {
        let length = Self.overlayLength(scale: overlayScale, themed: themed)
        let c = resolvedCenter(themed: themed)
        return Frame(x: c.x - length / 2, y: c.y - length / 2, width: length, height: length)
    }

    /// 拖动：从起点中心 start 开始，手指移动了 (dx, dy)（占画布的比例），得到新的中心点（夹好）。
    static func dragged(from start: Point, dx: Double, dy: Double, length: Double) -> Point {
        clampCenter(Point(x: start.x + (dx.isFinite ? dx : 0), y: start.y + (dy.isFinite ? dy : 0)), length: length)
    }

    /// 贴纸白边的宽度，占叠加层边长的比例。
    static let stickerBorderRatio = 0.06

    static func clampHue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, hueRange.lowerBound), hueRange.upperBound).rounded()
    }

    /// 只接受「小写字母数字和 - 组成的 分类/名字」，防止拼出别的路径。
    static func normalizedTheme(_ text: String?) -> String? {
        guard let text else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let ok = parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ($0.isLetter && $0.isASCII && $0.isLowercase) || ($0.isNumber && $0.isASCII) || $0 == "-" }
        }
        return ok ? text : nil
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

    private enum CodingKeys: String, CodingKey { case color, overlay, overlayScale, theme, hue, backdrop, overlayCenter }
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
        let theme = try c.decodeIfPresent(String.self, forKey: .theme)
        let hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        let themed = FolderIconStyle.normalizedTheme(theme) != nil
        // 旧样式没有 backdrop：照旧的样子（主题上圆底、普通上色不垫），已经换装的图标不会突然变样。不认识的值也这样处理。
        let backdrop = (try? c.decodeIfPresent(String.self, forKey: .backdrop)).flatMap(Backdrop.init(rawValue:))
            ?? FolderIconStyle.legacyBackdrop(themed: themed)
        let center = try? c.decodeIfPresent(Point.self, forKey: .overlayCenter)
        self.init(color: hex, overlay: overlay, overlayScale: scale, theme: theme, hue: hue,
                  backdrop: backdrop, overlayCenter: center)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(overlayScale, forKey: .overlayScale)
        try c.encodeIfPresent(theme, forKey: .theme)
        if theme != nil { try c.encode(hue, forKey: .hue) }
        try c.encode(backdrop.rawValue, forKey: .backdrop)
        try c.encodeIfPresent(overlayCenter, forKey: .overlayCenter)
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
    /// 文件夹的 inode。文件夹在拾掇外面被移动或改名后，靠它找回记录。旧记录没有。
    var fileNumber: UInt64?
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
    mutating func recordApplied(_ style: FolderIconStyle, path: String, hadCustomIcon: Bool, backupFile: String?,
                                fileNumber: UInt64? = nil, date: Date = Date()) {
        if var existing = folders[path] {
            existing.style = style
            existing.date = date
            if let fileNumber { existing.fileNumber = fileNumber }
            folders[path] = existing
        } else {
            folders[path] = FolderIconRecord(style: style, hadCustomIcon: hadCustomIcon, backupFile: backupFile,
                                             date: date, fileNumber: fileNumber)
        }
    }

    /// 这个路径上的文件夹（inode 是 fileNumber）对应哪条记录，没有返回 nil。
    /// - 路径上有记录、inode 对得上（旧记录没存 inode、或者读不到 inode 时没法比，也算）：就是它；
    /// - 路径上的记录 inode 对不上：这条路径已经换成了别的文件夹（原来的被改名 / 移走后又新建了同名的），
    ///   那条记录不属于它，再按 inode 找它自己的；
    /// - 路径上没有记录：按 inode 找在拾掇外面被移走的那条。
    func ownerKey(for path: String, fileNumber: UInt64?, inodeAt: (String) -> UInt64?) -> String? {
        if let record = folders[path], Self.sameFolder(record, fileNumber) { return path }
        return staleKey(for: path, fileNumber: fileNumber, inodeAt: inodeAt)
    }

    /// 记录和当前文件夹是不是同一个（有一边没有 inode 时没法比，当作是）。
    static func sameFolder(_ record: FolderIconRecord, _ fileNumber: UInt64?) -> Bool {
        guard let recorded = record.fileNumber, let fileNumber else { return true }
        return recorded == fileNumber
    }

    /// 找一条「同一个磁盘上、inode 相同、原路径已经不在或者已经换成别的文件夹」的记录——
    /// 说明这个文件夹是在拾掇外面（访达、其他 App）被移动或改名的。找不到返回 nil。
    func staleKey(for path: String, fileNumber: UInt64?, inodeAt: (String) -> UInt64?) -> String? {
        guard let fileNumber else { return nil }
        let volume = Self.volumeRoot(path)
        return folders.first { key, record in
            key != path && record.fileNumber == fileNumber && Self.volumeRoot(key) == volume && inodeAt(key) != fileNumber
        }?.key
    }

    /// 上色 / 还原前调用：把记录对到这个文件夹上，返回它的路径键。
    /// 路径上占着的是别的文件夹的记录时，把那条挪到「孤儿」键下（不丢，等那个文件夹在新位置被操作时按 inode 认领）。
    @discardableResult
    mutating func claim(_ path: String, fileNumber: UInt64?, inodeAt: (String) -> UInt64?,
                        orphanID: String = UUID().uuidString) -> String {
        if let record = folders[path], !Self.sameFolder(record, fileNumber) {
            folders[path] = nil
            folders[Self.orphanKey(path, id: orphanID)] = record
        }
        if folders[path] == nil, let old = staleKey(for: path, fileNumber: fileNumber, inodeAt: inodeAt) {
            movePath(old, to: path)
        }
        return path
    }

    /// 孤儿记录的键：原路径 + 一个控制字符 + 随机 ID。磁盘上不会有这个路径，也不会被当成谁的子文件夹。
    static func orphanKey(_ path: String, id: String) -> String { path + "\u{1}" + id }

    static func isOrphanKey(_ key: String) -> Bool { key.contains("\u{1}") }

    /// 「/Volumes/盘名」或「/」。inode 只在同一个磁盘里才唯一。
    static func volumeRoot(_ path: String) -> String {
        let path = path.components(separatedBy: "\u{1}")[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/" + parts[1] }
        return "/"
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

/// 上色会在文件夹里放一个隐藏的「Icon\r」文件。在 git 仓库、同步盘里给一行提示（不拦着）。
enum FolderIconSyncHint: Equatable {
    case git
    case cloud

    /// path：文件夹路径；isGitRepo：文件夹里或上层有没有 .git。纯逻辑，方便测试。
    static func detect(path: String, home: String, isGitRepo: Bool) -> FolderIconSyncHint? {
        if isGitRepo { return .git }
        let cloudRoots = [home + "/Library/Mobile Documents", home + "/Library/CloudStorage", home + "/Dropbox",
                          home + "/OneDrive", home + "/Google Drive", home + "/坚果云", home + "/Nutstore"]
        if cloudRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .cloud }
        // iCloud「桌面与文稿」：桌面、文稿在 iCloud 里时，访达给的仍是 ~/Desktop、~/Documents，这里不猜。
        return nil
    }
}

/// 「文件夹换装」自带的主题图标：分类和顺序。图在 App 里的 ThemeIcons/<分类>/<名字>.png。
enum FolderThemeCatalog {
    struct Category: Identifiable, Hashable {
        let id: String
        let symbol: String
        let items: [String]
        var title: String {
            switch id {
            case "food": return String(localized: "美食")
            case "animal": return String(localized: "动物")
            case "starry": return String(localized: "星空")
            case "planet": return String(localized: "星球")
            case "plant": return String(localized: "植物")
            case "material": return String(localized: "材质")
            case "building": return String(localized: "建筑")
            case "apple": return String(localized: "Apple")
            default: return id
            }
        }
        /// 完整的主题 ID（分类/名字）。
        var themes: [String] { items.map { id + "/" + $0 } }
    }

    static let categories: [Category] = [
        Category(id: "food", symbol: "fork.knife", items: ["cake", "donut", "matcha", "ramen", "sushi", "watermelon"]),
        Category(id: "animal", symbol: "pawprint.fill", items: ["cat", "dog", "bear", "panda", "rabbit", "fox",
                                                                 "coral-fish", "jellyfish", "octopus", "turtle",
                                                                 // 毛绒款（2026-10-31）：6 只常见动物 + 十二生肖 + 大象
                                                                 "plush-fox", "plush-panda", "plush-cat", "plush-bear",
                                                                 "plush-rabbit", "plush-shiba", "plush-elephant",
                                                                 "plush-mouse", "plush-ox", "plush-tiger", "plush-dragon",
                                                                 "plush-snake", "plush-horse", "plush-goat", "plush-monkey",
                                                                 "plush-rooster", "plush-puppy", "plush-pig"]),
        Category(id: "starry", symbol: "moon.stars.fill", items: ["aurora", "constellation", "galaxy", "galaxy-2", "moon", "moon-2",
                                                                   "shooting-star", "shooting-star-2", "stars"]),
        Category(id: "planet", symbol: "globe.asia.australia.fill", items: ["earth", "saturn", "jupiter", "mars", "ice", "pastel",
                                                                             "astronaut", "rover", "ufo"]),
        Category(id: "plant", symbol: "leaf.fill", items: ["monstera", "succulent", "bonsai", "palm", "sunflower", "tulip"]),
        Category(id: "material", symbol: "square.stack.3d.up.fill", items: ["frosted-glass", "gradient-glass", "holographic",
                                                                             "marble", "metal", "wood"]),
        Category(id: "building", symbol: "building.columns.fill", items: ["eiffel", "big-ben", "liberty", "opera-house",
                                                                           "taj-mahal", "pyramids"]),
        // Apple 致敬款（2026-10-31）：8 款经典机型 + 6 色笑脸小电脑
        Category(id: "apple", symbol: "apple.logo", items: ["apple-ii", "macintosh", "powerbook", "imac-g3", "ibook", "cube",
                                                            "imac-g4", "imac", "retro-rainbow", "retro-cream", "retro-blue",
                                                            "retro-mint", "retro-navy", "retro-red"]),
    ]

    static var allThemes: [String] { categories.flatMap(\.themes) }

    static func category(of theme: String) -> Category? {
        let id = theme.split(separator: "/").first.map(String.init)
        return categories.first { $0.id == id }
    }

    /// App 里图片的相对路径（ThemeIcons/animal/cat.png）。不认识的主题返回 nil。
    static func resourcePath(_ theme: String) -> String? {
        guard allThemes.contains(theme) else { return nil }
        return "ThemeIcons/" + theme + ".png"
    }
}
