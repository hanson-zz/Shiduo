import Foundation

// MARK: - 字体预览（字体库的网格 / 列表 / 正文排版）里不依赖界面、能单元测试的部分
// 样张预设、字距、统一视觉大小、辅助线位置、列表排序、正文排版样式。

// MARK: 样张预设

/// 一条样张预设：名字 + 句子。
struct FontSamplePreset: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var text: String

    var id: String { name + "\u{1}" + text }
}

enum FontSamplePresets {
    /// 自己存的预设放在 UserDefaults 的这一项（JSON）。
    static let storageKey = "fonts.samplePresets"
    /// 最多存几条自己的预设。
    static let maxCustom = 20

    /// 常用中文 / 英文 / 数字三条内置预设（句子本身不翻译：它是给字体看的，不是界面文字）。
    static let chineseText = "永和九年 Aa"
    static let englishText = "Handgloves"
    static let digitsText = "0123456789 ¥$€ 1/2 3.14"

    static var builtIn: [FontSamplePreset] {
        [
            FontSamplePreset(name: String(localized: "常用中文"), text: chineseText),
            FontSamplePreset(name: String(localized: "英文"), text: englishText),
            FontSamplePreset(name: String(localized: "数字"), text: digitsText),
        ]
    }

    static func decode(_ raw: String) -> [FontSamplePreset] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([FontSamplePreset].self, from: data) else { return [] }
        return list.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func encode(_ presets: [FontSamplePreset]) -> String {
        guard let data = try? JSONEncoder().encode(presets) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 存一条预设：句子是空的不存；名字空着就用句子开头；同名的覆盖；最多 maxCustom 条（挤掉最早的）。
    static func adding(name: String, text: String, to list: [FontSamplePreset]) -> [FontSamplePreset] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return list }
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = body.count > 12 ? String(body.prefix(12)) + "…" : body }
        var result = list.filter { $0.name != title }
        result.append(FontSamplePreset(name: title, text: body))
        if result.count > maxCustom { result.removeFirst(result.count - maxCustom) }
        return result
    }

    static func removing(name: String, from list: [FontSamplePreset]) -> [FontSamplePreset] {
        list.filter { $0.name != name }
    }

    /// 这张卡片实际显示的句子：字体不含汉字、句子里却有汉字时，换成句子里的英文部分（太短就用 Handgloves），
    /// 免得英文字体全是方框 / 系统替代字形。
    static func displayText(_ sample: String, coversCJK: Bool) -> String {
        let text = collapse(sample)
        if text.isEmpty { return coversCJK ? chineseText : englishText }
        guard !coversCJK, text.unicodeScalars.contains(where: isCJK) else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.map { isCJK($0) ? " " : $0 })
        let latin = collapse(String(view))
        let letters = latin.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return letters >= 4 ? latin : englishText
    }

    /// 汉字、中日韩标点、全角符号。
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: 字距

/// 字距：单位是千分之一个字（em），和设计软件里的「字距 +20」一样。
enum FontTracking {
    static let range: ClosedRange<Double> = -100...400

    static func clamp(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }

    /// 换成点数（NSKern 要的是点）。
    static func points(_ thousandths: Double, size: Double) -> Double { thousandths / 1000 * size }

    /// 按住 Option 双指缩放：张开一倍大约加 200。
    static func afterMagnify(base: Double, magnification: Double) -> Double {
        clamp(((base + (magnification - 1) * 200)).rounded())
    }

    static func label(_ value: Double) -> String {
        let v = Int(value.rounded())
        return v > 0 ? "+\(v)" : "\(v)"
    }
}

// MARK: 统一视觉大小、辅助线

/// 一个字体在某个字号下的几个高度（点）。从 CTFont 读，这里只算。
struct FontMetricsSample: Equatable, Sendable {
    var size: Double
    var ascent: Double
    var descent: Double
    var capHeight: Double
    var xHeight: Double
    /// 中文字体：按字身（ascent）对齐，不看 x 高（汉字没有 x 高，很多中文字体也不写）。
    var coversCJK: Bool
}

enum FontVisualSize {
    /// 西文按 x 高对齐到半个字号；没有 x 高的按大写高对齐到 0.7；中文按 ascent 对齐到 0.88。
    static let latinXHeight = 0.5
    static let latinCapHeight = 0.7
    static let cjkAscent = 0.88
    /// 放大缩小都有个限度（读错数据的字体不至于缩成一个点）。
    static let scaleRange: ClosedRange<Double> = 0.6...1.8

    /// 字号要乘的倍数：乘完后各字体「看起来」一样大。
    static func scale(_ m: FontMetricsSample) -> Double {
        guard m.size > 0 else { return 1 }
        let measured: Double
        let target: Double
        if m.coversCJK, m.ascent > 0 {
            measured = m.ascent
            target = cjkAscent
        } else if m.xHeight > 0 {
            measured = m.xHeight
            target = latinXHeight
        } else if m.capHeight > 0 {
            measured = m.capHeight
            target = latinCapHeight
        } else {
            return 1
        }
        let ratio = measured / m.size
        guard ratio > 0.05 else { return 1 }
        return min(max(target / ratio, scaleRange.lowerBound), scaleRange.upperBound)
    }
}

/// 辅助线：基线、x 高、大写高。
enum FontGuideKind: String, CaseIterable, Sendable {
    case baseline, xHeight, capHeight
}

struct FontGuideLine: Equatable, Sendable {
    var kind: FontGuideKind
    /// 离基线多高（点，往上为正）。
    var offset: Double
}

enum FontGuides {
    /// 要画的线（高度是 0 或和别的线重合的不画）。
    static func lines(_ m: FontMetricsSample) -> [FontGuideLine] {
        var result = [FontGuideLine(kind: .baseline, offset: 0)]
        for (kind, value) in [(FontGuideKind.xHeight, m.xHeight), (.capHeight, m.capHeight)] where value > 0.5 {
            if result.contains(where: { abs($0.offset - value) < 0.5 }) { continue }
            result.append(FontGuideLine(kind: kind, offset: value))
        }
        return result
    }

    /// 一行字竖直居中时基线的位置（坐标原点在下面，和 AppKit 默认一样）。
    static func baselineY(height: Double, ascent: Double, descent: Double) -> Double {
        (height - (ascent + descent)) / 2 + descent
    }
}

// MARK: 网格的颜色、网格 / 列表

enum FontPreviewColors: String, CaseIterable, Identifiable, Sendable {
    /// 黑字白底
    case blackOnWhite
    /// 白字黑底
    case whiteOnBlack
    /// 品牌色（跟着设置 › 外观 › 主题色）
    case accent

    var id: String { rawValue }
}

enum FontLibraryLayout: String, CaseIterable, Identifiable, Sendable {
    case grid, list
    var id: String { rawValue }
}

// MARK: 列表视图

/// 列表里要从字体文件另外读的几项（厂商、设计师、字数……），后台读好后缓存。
struct FontExtraInfo: Equatable, Sendable {
    var manufacturer: String = ""
    var designer: String = ""
    var glyphCount: Int = 0
    var copyright: String = ""
    var trademark: String = ""
    var descriptionText: String = ""
}

enum FontListColumn: String, CaseIterable, Identifiable, Sendable {
    case name, styles, format, version, manufacturer, glyphs, added, designer, path, size, license
    var id: String { rawValue }
}

/// 列表排序：哪一列、正序还是倒序。存成「version:desc」这样的字符串。
struct FontListSort: Equatable, Sendable {
    var column: FontListColumn
    var ascending: Bool

    static let `default` = FontListSort(column: .name, ascending: true)

    var rawValue: String { column.rawValue + ":" + (ascending ? "asc" : "desc") }

    init(column: FontListColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":").map(String.init)
        guard parts.count == 2, let column = FontListColumn(rawValue: parts[0]), parts[1] == "asc" || parts[1] == "desc" else { return nil }
        self.init(column: column, ascending: parts[1] == "asc")
    }
}

/// 列表里的一行（一个字体家族）。
struct FontListRow: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var styleCount: Int
    var format: String
    var version: String
    /// 排序用的版本号（读不出数字是 -1）。
    var versionKey: Decimal
    var manufacturer: String
    var glyphCount: Int
    var added: Date
    var designer: String
    var path: String
    var bytes: Int64
    var license: String
}

enum FontListLogic {
    /// 一个家族变成一行。extra 是代表字形另外读的信息（还没读到时是 nil，先空着）。
    static func row(_ family: FontFamily, extra: FontExtraInfo?, license: String) -> FontListRow {
        let face = family.representative
        let versionText = face?.version ?? ""
        return FontListRow(
            id: family.id,
            name: family.displayName,
            styleCount: family.styleCount,
            format: family.formats.map(\.label).joined(separator: "/"),
            version: FontVersion.number(versionText) ?? versionText,
            versionKey: FontVersion.parse(versionText) ?? -1,
            manufacturer: extra?.manufacturer ?? "",
            glyphCount: extra?.glyphCount ?? 0,
            added: family.newestAdded ?? .distantPast,
            designer: extra?.designer ?? "",
            path: face?.path ?? "",
            bytes: family.totalBytes,
            license: license
        )
    }

    static func sorted(_ rows: [FontListRow], by sort: FontListSort) -> [FontListRow] {
        rows.sorted { a, b in
            let result = compare(a, b, sort.column)
            if result != .orderedSame { return sort.ascending ? result == .orderedAscending : result == .orderedDescending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func compare(_ a: FontListRow, _ b: FontListRow, _ column: FontListColumn) -> ComparisonResult {
        func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
        switch column {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .styles: return order(a.styleCount, b.styleCount)
        case .format: return a.format.localizedStandardCompare(b.format)
        case .version: return order(a.versionKey, b.versionKey)
        case .manufacturer: return a.manufacturer.localizedStandardCompare(b.manufacturer)
        case .glyphs: return order(a.glyphCount, b.glyphCount)
        case .added: return order(a.added, b.added)
        case .designer: return a.designer.localizedStandardCompare(b.designer)
        case .path: return a.path.localizedStandardCompare(b.path)
        case .size: return order(a.bytes, b.bytes)
        case .license: return a.license.localizedStandardCompare(b.license)
        }
    }

    /// 表头的排序（SwiftUI Table 用 KeyPathComparator）和存下来的排序互相换。
    static func keyPath(_ column: FontListColumn) -> PartialKeyPath<FontListRow> {
        switch column {
        case .name: return \FontListRow.name
        case .styles: return \FontListRow.styleCount
        case .format: return \FontListRow.format
        case .version: return \FontListRow.versionKey
        case .manufacturer: return \FontListRow.manufacturer
        case .glyphs: return \FontListRow.glyphCount
        case .added: return \FontListRow.added
        case .designer: return \FontListRow.designer
        case .path: return \FontListRow.path
        case .size: return \FontListRow.bytes
        case .license: return \FontListRow.license
        }
    }

    static func column(for keyPath: PartialKeyPath<FontListRow>) -> FontListColumn? {
        FontListColumn.allCases.first { self.keyPath($0) == keyPath }
    }

    static func comparator(_ sort: FontListSort) -> KeyPathComparator<FontListRow> {
        let order: SortOrder = sort.ascending ? .forward : .reverse
        switch sort.column {
        case .name: return KeyPathComparator(\FontListRow.name, order: order)
        case .styles: return KeyPathComparator(\FontListRow.styleCount, order: order)
        case .format: return KeyPathComparator(\FontListRow.format, order: order)
        case .version: return KeyPathComparator(\FontListRow.versionKey, order: order)
        case .manufacturer: return KeyPathComparator(\FontListRow.manufacturer, order: order)
        case .glyphs: return KeyPathComparator(\FontListRow.glyphCount, order: order)
        case .added: return KeyPathComparator(\FontListRow.added, order: order)
        case .designer: return KeyPathComparator(\FontListRow.designer, order: order)
        case .path: return KeyPathComparator(\FontListRow.path, order: order)
        case .size: return KeyPathComparator(\FontListRow.bytes, order: order)
        case .license: return KeyPathComparator(\FontListRow.license, order: order)
        }
    }

    /// 点了表头：Table 给回来的排序换成存的排序（认不出的列保持原样）。
    static func sort(from comparators: [KeyPathComparator<FontListRow>], current: FontListSort) -> FontListSort {
        guard let first = comparators.first, let column = column(for: first.keyPath) else { return current }
        return FontListSort(column: column, ascending: first.order == .forward)
    }
}

extension FontVersion {
    /// 「Version 1.002;PS 1.2」→「1.002」（原样保留写法，1.00 不会变成 1）；没有数字返回 nil。
    static func number(_ text: String) -> String? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i].isASCII, chars[i].isNumber {
                var j = i
                var sawDot = false
                while j < chars.count {
                    let c = chars[j]
                    if c.isASCII, c.isNumber { j += 1; continue }
                    if c == ".", !sawDot, j + 1 < chars.count, chars[j + 1].isASCII, chars[j + 1].isNumber {
                        sawDot = true
                        j += 1
                        continue
                    }
                    break
                }
                return String(chars[i..<j])
            }
            i += 1
        }
        return nil
    }
}

// MARK: 正文排版

enum FontBodyStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case book, magazine, web, custom
    var id: String { rawValue }
}

/// 一页正文样张：栏目、标题、副标题、正文（空行分段）、字号、行距（倍数）、分几栏。
struct FontBodySpecimen: Codable, Equatable, Sendable {
    var kicker: String
    var title: String
    var subtitle: String
    var body: String
    var titleSize: Double
    var bodySize: Double
    var leading: Double
    var columns: Int
}

enum FontBodyLogic {
    static let storageKey = "fonts.bodyCustom"
    static let titleRange: ClosedRange<Double> = 14...72
    static let bodyRange: ClosedRange<Double> = 9...32
    static let leadingRange: ClosedRange<Double> = 1.0...2.6
    static let columnRange: ClosedRange<Int> = 1...3

    // 样张文字（给字体看的内容，不是界面文字，不翻译）。
    static let zhKicker = "专题 · 烘焙"
    static let zhTitle = "一块黄油的旅行"
    static let zhSubtitle = "从牧场到烤箱，原料决定了面包的灵魂"
    static let zhBody = """
    清晨五点，奶罐车驶出牧场。新鲜的奶油在低温中慢慢搅打，水分一点点析出，留下金黄细腻的脂肪。好的黄油有淡淡的奶香和坚果味，融点刚好落在口腔的温度，入口即化。

    回到烘焙房，师傅把冷藏的黄油切成小块，和面粉一起揉搓成沙粒状。温度是关键，手心的热量都会让油脂过早融化，层次就出不来了。

    发酵黄油带着微微的酸香，做可颂最出彩；无盐黄油让配方更好控制，是大多数面包店的首选。

    一块好黄油，经过折叠、擀压、冷藏，再折叠，最终在烤箱里膨胀出上百层酥皮，这就是它旅行的终点。
    """
    static let enKicker = "FEATURE · BAKING"
    static let enTitle = "The Journey of Butter"
    static let enSubtitle = "From pasture to oven, ingredients shape the soul of bread"
    static let enBody = """
    At five in the morning the milk truck leaves the farm. Fresh cream is churned slowly in the cold until the water separates, leaving a golden, silky fat with a faint scent of milk and hazelnut.

    Back in the bakery, the baker cuts chilled butter into cubes and rubs it into the flour until it looks like sand. Temperature is everything: even the warmth of a palm can melt the fat too early and flatten the layers.

    Cultured butter brings a gentle tang that makes croissants shine; unsalted butter keeps the recipe under control and is the choice of most bakeries.

    Folded, rolled, chilled and folded again, a good block of butter finally rises into a hundred flaky layers in the oven. That is the end of its journey.
    """

    /// 预设的样式（中文字体用中文稿，西文字体用英文稿）。custom 返回自定义的默认值。
    static func preset(_ style: FontBodyStyle, cjk: Bool) -> FontBodySpecimen {
        let kicker = cjk ? zhKicker : enKicker
        let title = cjk ? zhTitle : enTitle
        let subtitle = cjk ? zhSubtitle : enSubtitle
        let body = cjk ? zhBody : enBody
        switch style {
        case .book:
            // 书籍：单栏、行距宽、段首缩进两个字，没有栏目和副标题。
            let indented = paragraphs(body).map { cjk ? "\u{3000}\u{3000}" + $0 : $0 }.joined(separator: "\n\n")
            return FontBodySpecimen(kicker: "", title: title, subtitle: "", body: indented,
                                    titleSize: 22, bodySize: 14, leading: 1.8, columns: 1)
        case .magazine:
            return FontBodySpecimen(kicker: kicker, title: title, subtitle: subtitle, body: body,
                                    titleSize: 32, bodySize: 12.5, leading: 1.65, columns: 2)
        case .web:
            return FontBodySpecimen(kicker: "", title: title, subtitle: subtitle, body: body,
                                    titleSize: 26, bodySize: 15, leading: 1.55, columns: 1)
        case .custom:
            return FontBodySpecimen(kicker: "", title: title, subtitle: subtitle, body: body,
                                    titleSize: 28, bodySize: 14, leading: 1.6, columns: 1)
        }
    }

    /// 标题用哪个字形：家族里有偏粗的（Semibold / Bold / Medium / W6 / 粗 / 中黑……）就用它，斜体不算；没有返回 nil。
    static func titleFace(in faces: [FontFace]) -> FontFace? {
        let keys = ["semibold", "demibold", "bold", "medium", "heavy", "w6", "w7", "中黑", "粗"]
        let usable = faces.filter { !$0.isDamaged && !$0.style.lowercased().contains("italic") && !$0.style.contains("斜") }
        for key in keys {
            if let face = usable.first(where: { $0.style.lowercased().contains(key) }) { return face }
        }
        return nil
    }

    /// 正文按空行 / 换行分段（去掉空段）。
    static func paragraphs(_ body: String) -> [String] {
        body.components(separatedBy: .newlines)
            // 只去掉半角空格和 tab：全角空格（段首缩进）要留着。
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty }
    }

    /// 分栏：按字数尽量平均，段落顺序不变；总是返回 count 栏（有的可能是空的）。
    static func columns(_ paragraphs: [String], count: Int) -> [[String]] {
        let n = max(1, count)
        guard n > 1 else { return [paragraphs] }
        var result = Array(repeating: [String](), count: n)
        let total = paragraphs.reduce(0) { $0 + $1.count }
        var used = 0
        var column = 0
        for paragraph in paragraphs {
            // 这一栏已经够它该分的份额了（且不是最后一栏）：换下一栏。
            if column < n - 1, !result[column].isEmpty, Double(used) >= Double(total) * Double(column + 1) / Double(n) {
                column += 1
            }
            result[column].append(paragraph)
            used += paragraph.count
        }
        return result
    }

    /// 行距倍数换成 SwiftUI lineSpacing 要的点数（行与行之间多出来的空白）。
    static func lineSpacing(size: Double, leading: Double) -> Double {
        max(0, (leading - 1.2) * size)
    }

    static func clamped(_ spec: FontBodySpecimen) -> FontBodySpecimen {
        var s = spec
        s.titleSize = min(max(s.titleSize, titleRange.lowerBound), titleRange.upperBound)
        s.bodySize = min(max(s.bodySize, bodyRange.lowerBound), bodyRange.upperBound)
        s.leading = min(max(s.leading, leadingRange.lowerBound), leadingRange.upperBound)
        s.columns = min(max(s.columns, columnRange.lowerBound), columnRange.upperBound)
        return s
    }

    static func encode(_ spec: FontBodySpecimen) -> String {
        guard let data = try? JSONEncoder().encode(clamped(spec)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ raw: String) -> FontBodySpecimen? {
        guard let data = raw.data(using: .utf8), let spec = try? JSONDecoder().decode(FontBodySpecimen.self, from: data) else { return nil }
        return clamped(spec)
    }
}

// MARK: - 窄窗口排版

enum FontLayoutLogic {
    /// 网格每列的最小宽度：按字号算（字越大卡片越宽），但不超过实际能用的宽度（窗口再窄也不裁掉卡片）。
    static func gridMinimum(size: Double, available: CGFloat) -> CGFloat {
        let wanted = max(240, CGFloat(size) * 6.5)
        guard available > 0 else { return wanted }
        return max(120, min(wanted, available))
    }

    /// 字体库右边详情面板的宽度：平时 440；窗口窄时最多占一半，最少 260。
    static func detailWidth(total: CGFloat) -> CGFloat {
        guard total > 0 else { return 440 }
        return min(440, max(260, total * 0.5))
    }
}
