import CoreGraphics
import Foundation

// MARK: - 字体细节（Pro）里不依赖界面、能单元测试的部分
// 字符表（分类、搜索、Unicode 区块）、字形路径转 SVG、OpenType 特性（读 GSUB / GPOS 的特性表、中文名）、
// 可变字体（读 fvar 的轴和命名样式、name 表、复制 CSS）、彩色字体调色板（读 CPAL）。

// MARK: 读字体表用的小工具（大端序，越界返回 nil）

struct FontTableReader {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    func u8(_ offset: Int) -> UInt8? {
        offset >= 0 && offset < bytes.count ? bytes[offset] : nil
    }

    func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    /// 16.16 定点数。
    func fixed(_ offset: Int) -> Double? {
        u32(offset).map { Double(Int32(bitPattern: $0)) / 65536 }
    }

    /// 4 个字节的标签（「wght」「liga」）。
    func tag(_ offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let chars = bytes[offset..<offset + 4]
        guard chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: chars, as: UTF8.self)
    }
}

enum FontTag {
    /// 「wght」→ 0x77676874（Core Text 用整数表示轴和表）。
    static func code(_ tag: String) -> UInt32 {
        let bytes = Array(tag.utf8.prefix(4)) + Array(repeating: UInt8(0x20), count: max(0, 4 - tag.utf8.count))
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: 字符表

enum FontCharCategory: String, CaseIterable, Identifiable, Sendable {
    case all, han, latin, digit, symbol
    var id: String { rawValue }
}

enum FontCharsetLogic {
    /// 字符多的字体（中文字体动辄几万字）一次只摆这么多格，往下再加载。
    static let pageSize = 1200

    /// 字体支持的所有字符（码位从小到大）。跳过控制字符和空白（格子里看不见）。
    static func scalars(in set: CharacterSet) -> [UInt32] {
        var result: [UInt32] = []
        for plane in UInt8(0)...16 where set.hasMember(inPlane: plane) {
            let start = UInt32(plane) << 16
            for value in start...(start + 0xFFFF) {
                guard let scalar = Unicode.Scalar(value), set.contains(scalar), isVisible(scalar) else { continue }
                result.append(value)
            }
        }
        return result
    }

    static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return false }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) { return false } // 变体选择符
        if (0x200B...0x200F).contains(v) || (0x2028...0x202E).contains(v) || (0x2060...0x206F).contains(v) || v == 0xFEFF { return false }
        return v != 0xFFFE && v != 0xFFFF
    }

    static func isHan(_ v: UInt32) -> Bool {
        switch v {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F, 0x2E80...0x2FDF, 0x3005, 0x3007:
            return true
        default:
            return false
        }
    }

    static func isLatin(_ v: UInt32) -> Bool {
        switch v {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF,
             0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }

    static func isDigit(_ v: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(v) else { return false }
        if CharacterSet.decimalDigits.contains(scalar) { return true }
        // 上标 / 下标数字、带圈数字、罗马数字、分数也算「数字」。
        switch v {
        case 0xB2, 0xB3, 0xB9, 0xBC...0xBE, 0x2070...0x2079, 0x2080...0x2089, 0x2150...0x218B, 0x2460...0x249B, 0x24EA...0x24FF, 0x3021...0x3029:
            return true
        default:
            return false
        }
    }

    static func isSymbol(_ v: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(v), !isDigit(v), !isLatin(v), !isHan(v) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }

    static func matches(_ v: UInt32, _ category: FontCharCategory) -> Bool {
        switch category {
        case .all: return true
        case .han: return isHan(v)
        case .latin: return isLatin(v)
        case .digit: return isDigit(v)
        case .symbol: return isSymbol(v)
        }
    }

    static func filter(_ scalars: [UInt32], _ category: FontCharCategory) -> [UInt32] {
        category == .all ? scalars : scalars.filter { matches($0, category) }
    }

    /// 搜索框：「U+6C38」「u+6c38」「0x6C38」「6C38」（4–6 位、带数字）→ 那个码位；其他 → 输入的每个字（去重、保持顺序）。
    static func search(_ query: String) -> [UInt32] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        var hex: Substring?
        if lower.hasPrefix("u+") || lower.hasPrefix("0x") {
            hex = lower.dropFirst(2)
        } else if (4...6).contains(lower.count), lower.allSatisfy(\.isHexDigit), lower.contains(where: \.isNumber) {
            hex = Substring(lower)
        }
        if let hex, !hex.isEmpty, hex.count <= 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16),
           Unicode.Scalar(value) != nil {
            return [value]
        }
        var seen = Set<UInt32>()
        return q.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }.map(\.value).filter { seen.insert($0).inserted }
    }

    /// 「U+6C38」「U+1F600」：至少 4 位。
    static func codeText(_ v: UInt32) -> String {
        "U+" + String(format: "%04X", v)
    }

    /// 码位在哪个 Unicode 区块（常见的那些；其余叫「其他」）。
    static func block(_ v: UInt32) -> FontUnicodeBlock {
        FontUnicodeBlock.all.first { $0.range.contains(v) } ?? FontUnicodeBlock(range: v...v, key: .other)
    }

    /// 「和其他字体比较」挑哪些字体：先「对比」里的，再「常用」，去掉自己，去重，最多 limit 个。
    static func compareCandidates(current: String, compare: [String], favorites: [String], limit: Int = 8) -> [String] {
        var seen: Set<String> = [current]
        return (compare + favorites).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }
}

/// Unicode 区块。名字的翻译在界面那边（FontUnicodeBlock.Key.title）。
struct FontUnicodeBlock: Equatable, Sendable {
    enum Key: String, Sendable {
        case basicLatin, latin1, latinExtA, latinExtB, ipa, modifiers, combining, greek, cyrillic, hebrew, arabic, thai
        case latinExtAdditional, punctuation, superSub, currency, letterlike, numberForms, arrows, math, technical
        case enclosedAlnum, boxDrawing, shapes, miscSymbols, dingbats, cjkRadicals, kangxi, cjkPunctuation
        case hiragana, katakana, bopomofo, enclosedCJK, cjkCompat, cjkExtA, cjkUnified, hangul, privateUse
        case cjkCompatIdeographs, presentationForms, cjkCompatForms, fullwidth, pictographs, emoticons
        case cjkExtB, cjkExtCF, cjkExtG, other
    }

    var range: ClosedRange<UInt32>
    var key: Key

    static let all: [FontUnicodeBlock] = [
        .init(range: 0x0000...0x007F, key: .basicLatin),
        .init(range: 0x0080...0x00FF, key: .latin1),
        .init(range: 0x0100...0x017F, key: .latinExtA),
        .init(range: 0x0180...0x024F, key: .latinExtB),
        .init(range: 0x0250...0x02AF, key: .ipa),
        .init(range: 0x02B0...0x02FF, key: .modifiers),
        .init(range: 0x0300...0x036F, key: .combining),
        .init(range: 0x0370...0x03FF, key: .greek),
        .init(range: 0x0400...0x04FF, key: .cyrillic),
        .init(range: 0x0590...0x05FF, key: .hebrew),
        .init(range: 0x0600...0x06FF, key: .arabic),
        .init(range: 0x0E00...0x0E7F, key: .thai),
        .init(range: 0x1E00...0x1EFF, key: .latinExtAdditional),
        .init(range: 0x2000...0x206F, key: .punctuation),
        .init(range: 0x2070...0x209F, key: .superSub),
        .init(range: 0x20A0...0x20CF, key: .currency),
        .init(range: 0x2100...0x214F, key: .letterlike),
        .init(range: 0x2150...0x218F, key: .numberForms),
        .init(range: 0x2190...0x21FF, key: .arrows),
        .init(range: 0x2200...0x22FF, key: .math),
        .init(range: 0x2300...0x23FF, key: .technical),
        .init(range: 0x2460...0x24FF, key: .enclosedAlnum),
        .init(range: 0x2500...0x257F, key: .boxDrawing),
        .init(range: 0x25A0...0x25FF, key: .shapes),
        .init(range: 0x2600...0x26FF, key: .miscSymbols),
        .init(range: 0x2700...0x27BF, key: .dingbats),
        .init(range: 0x2E80...0x2EFF, key: .cjkRadicals),
        .init(range: 0x2F00...0x2FDF, key: .kangxi),
        .init(range: 0x3000...0x303F, key: .cjkPunctuation),
        .init(range: 0x3040...0x309F, key: .hiragana),
        .init(range: 0x30A0...0x30FF, key: .katakana),
        .init(range: 0x3100...0x312F, key: .bopomofo),
        .init(range: 0x3200...0x32FF, key: .enclosedCJK),
        .init(range: 0x3300...0x33FF, key: .cjkCompat),
        .init(range: 0x3400...0x4DBF, key: .cjkExtA),
        .init(range: 0x4E00...0x9FFF, key: .cjkUnified),
        .init(range: 0xAC00...0xD7AF, key: .hangul),
        .init(range: 0xE000...0xF8FF, key: .privateUse),
        .init(range: 0xF900...0xFAFF, key: .cjkCompatIdeographs),
        .init(range: 0xFB00...0xFB4F, key: .presentationForms),
        .init(range: 0xFE30...0xFE4F, key: .cjkCompatForms),
        .init(range: 0xFF00...0xFFEF, key: .fullwidth),
        .init(range: 0x1F300...0x1F5FF, key: .pictographs),
        .init(range: 0x1F600...0x1F64F, key: .emoticons),
        .init(range: 0x20000...0x2A6DF, key: .cjkExtB),
        .init(range: 0x2A700...0x2EBEF, key: .cjkExtCF),
        .init(range: 0x30000...0x3134F, key: .cjkExtG),
    ]
}

// MARK: 字形 → SVG

enum FontPathElement: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint)
    case close
}

enum FontSVGLogic {
    /// 数字：最多两位小数，去掉多余的 0（「12」「3.5」「-0.25」）。
    static func number(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// 字体坐标（y 往上）换成 SVG 坐标（y 往下，顶边是 ascent）。
    static func pathData(_ elements: [FontPathElement], ascent: CGFloat) -> String {
        func p(_ point: CGPoint) -> String { number(point.x) + " " + number(ascent - point.y) }
        return elements.map { element -> String in
            switch element {
            case let .move(a): return "M" + p(a)
            case let .line(a): return "L" + p(a)
            case let .quad(c, a): return "Q" + p(c) + " " + p(a)
            case let .cubic(c1, c2, a): return "C" + p(c1) + " " + p(c2) + " " + p(a)
            case .close: return "Z"
            }
        }.joined()
    }

    /// 整个 SVG 文件：宽 = 字宽（advance），高 = ascent + descent，单位是字体单位。
    static func svg(_ elements: [FontPathElement], advance: CGFloat, ascent: CGFloat, descent: CGFloat, title: String) -> String {
        let width = number(max(advance, 1))
        let height = number(max(ascent + descent, 1))
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
          <title>\(escape(title))</title>
          <path d="\(pathData(elements, ascent: ascent))" fill="#000000"/>
        </svg>

        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 存盘的文件名：「思源宋体-U+6C38.svg」（去掉文件名里不能用的字符）。
    static func fileName(fontName: String, scalar: UInt32) -> String {
        let cleaned = fontName.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "glyph" : cleaned) + "-" + FontCharsetLogic.codeText(scalar) + ".svg"
    }
}

// MARK: OpenType 特性

/// GSUB / GPOS 特性表里的一项：标签，和样式集 / 字符变体自带的名字在 name 表里的编号。
struct FontLayoutFeature: Equatable, Sendable {
    var tag: String
    var uiNameID: Int?
}

enum FontFeatureLogic {
    /// 字体内部用、用户开关没意义的特性（排版引擎自己会开），还有竖排专用的（横排预览看不出来）。
    static let hidden: Set<String> = [
        "ccmp", "locl", "mark", "mkmk", "rlig", "rclt", "init", "medi", "fina", "isol", "med2", "fin2", "fin3",
        "abvm", "blwm", "abvs", "blws", "dist", "curs", "akhn", "rphf", "blwf", "half", "pstf", "vatu", "cjct",
        "pres", "psts", "haln", "nukt", "rkrf", "pref", "abvf", "rand", "numr", "dnom", "aalt", "ljmo", "vjmo",
        "tjmo", "vert", "vrt2", "vkrn", "vpal", "valt", "vhal", "vrtr", "size", "ltra", "ltrm", "rtla", "rtlm",
    ]

    /// 系统默认就开着的。
    static let onByDefault: Set<String> = ["liga", "clig", "calt", "kern", "rlig", "ccmp", "locl", "mark", "mkmk", "curs", "dist"]

    /// 列表里的顺序：常用的在前，其余按标签字母。
    static let order = ["liga", "dlig", "hlig", "clig", "calt", "kern", "onum", "lnum", "tnum", "pnum", "frac", "afrc", "sups", "subs",
                        "sinf", "ordn", "smcp", "c2sc", "pcap", "c2pc", "case", "cpsp", "unic", "zero", "swsh", "cswh", "salt", "hist",
                        "titl", "ornm", "nalt", "expt", "trad", "smpl", "jp78", "jp83", "jp90", "jp04", "fwid", "hwid", "pwid",
                        "palt", "halt", "ruby", "mgrk"]

    /// 读 GSUB / GPOS 表的特性清单（标签可能重复：每种文字一份）。读不出来返回空。
    static func layoutFeatures(_ data: Data) -> [FontLayoutFeature] {
        let r = FontTableReader(data)
        guard let major = r.u16(0), major == 1, let listOffset = r.u16(6), listOffset > 0, let count = r.u16(listOffset) else { return [] }
        var result: [FontLayoutFeature] = []
        for i in 0..<min(count, 2000) {
            let record = listOffset + 2 + i * 6
            guard let tag = r.tag(record), let featureOffset = r.u16(record + 4) else { break }
            var nameID: Int?
            // 样式集（ssXX）和字符变体（cvXX）的 FeatureParams 里第 2 个字段是名字在 name 表里的编号。
            if tag.hasPrefix("ss") || tag.hasPrefix("cv") {
                let feature = listOffset + featureOffset
                if let paramsOffset = r.u16(feature), paramsOffset > 0, let id = r.u16(feature + paramsOffset + 2), id > 255 {
                    nameID = id
                }
            }
            result.append(FontLayoutFeature(tag: tag, uiNameID: nameID))
        }
        return result
    }

    /// 去重、去掉内部特性、按常用顺序排。
    static func visible(_ features: [FontLayoutFeature]) -> [FontLayoutFeature] {
        var byTag: [String: FontLayoutFeature] = [:]
        for feature in features where !hidden.contains(feature.tag) {
            if let existing = byTag[feature.tag], existing.uiNameID != nil { continue }
            byTag[feature.tag] = feature
        }
        return byTag.values.sorted { a, b in
            let ia = order.firstIndex(of: a.tag) ?? Int.max
            let ib = order.firstIndex(of: b.tag) ?? Int.max
            if ia != ib { return ia < ib }
            return a.tag < b.tag
        }
    }

    static func isOnByDefault(_ tag: String) -> Bool { onByDefault.contains(tag) }

    /// 「ss03」→ 3；不是样式集 / 字符变体返回 nil。
    static func variantNumber(_ tag: String) -> Int? {
        guard tag.hasPrefix("ss") || tag.hasPrefix("cv") else { return nil }
        return Int(tag.dropFirst(2))
    }

    /// 和默认不一样的开关（要交给 Core Text 的）：开了默认关的 = 1，关了默认开的 = 0。
    static func changes(_ states: [String: Bool]) -> [(tag: String, value: Int)] {
        states.keys.sorted().compactMap { tag -> (tag: String, value: Int)? in
            let on = states[tag] ?? isOnByDefault(tag)
            return on == isOnByDefault(tag) ? nil : (tag, on ? 1 : 0)
        }
    }

    /// 网页用的 CSS：font-feature-settings: "onum" 1, "liga" 0;（没改动返回 nil）。
    static func css(_ states: [String: Bool]) -> String? {
        let list = changes(states)
        guard !list.isEmpty else { return nil }
        return "font-feature-settings: " + list.map { "\"\($0.tag)\" \($0.value)" }.joined(separator: ", ") + ";"
    }
}

// MARK: 可变字体

struct FontAxisInfo: Equatable, Sendable, Identifiable {
    var tag: String
    var minValue: Double
    var defaultValue: Double
    var maxValue: Double
    var nameID: Int
    var hidden: Bool

    var id: String { tag }
}

struct FontNamedInstance: Equatable, Sendable {
    var nameID: Int
    var coordinates: [Double]
}

enum FontVariationLogic {
    /// 读 fvar 表：轴和命名样式。读不出来返回 nil。
    static func parseFvar(_ data: Data) -> (axes: [FontAxisInfo], instances: [FontNamedInstance])? {
        let r = FontTableReader(data)
        guard let major = r.u16(0), major == 1, let axesOffset = r.u16(4), let axisCount = r.u16(8), let axisSize = r.u16(10),
              let instanceCount = r.u16(12), let instanceSize = r.u16(14), axisSize >= 20, axisCount > 0 else { return nil }
        var axes: [FontAxisInfo] = []
        for i in 0..<axisCount {
            let o = axesOffset + i * axisSize
            guard let tag = r.tag(o), let lo = r.fixed(o + 4), let def = r.fixed(o + 8), let hi = r.fixed(o + 12),
                  let flags = r.u16(o + 16), let nameID = r.u16(o + 18) else { return nil }
            axes.append(FontAxisInfo(tag: tag, minValue: lo, defaultValue: def, maxValue: hi, nameID: nameID, hidden: flags & 1 != 0))
        }
        var instances: [FontNamedInstance] = []
        let start = axesOffset + axisCount * axisSize
        if instanceSize >= 4 + axisCount * 4 {
            for i in 0..<instanceCount {
                let o = start + i * instanceSize
                guard let nameID = r.u16(o) else { break }
                var coords: [Double] = []
                for a in 0..<axisCount {
                    guard let value = r.fixed(o + 4 + a * 4) else { break }
                    coords.append(value)
                }
                guard coords.count == axisCount else { break }
                instances.append(FontNamedInstance(nameID: nameID, coordinates: coords))
            }
        }
        return (axes, instances)
    }

    /// 数值显示：整数不带小数点，其余最多两位。
    static func number(_ value: Double) -> String {
        FontSVGLogic.number(CGFloat(value))
    }

    /// 复制 CSS：font-variation-settings: "wght" 600, "wdth" 100;
    static func css(_ values: [(tag: String, value: Double)]) -> String {
        guard !values.isEmpty else { return "font-variation-settings: normal;" }
        return "font-variation-settings: " + values.map { "\"\($0.tag)\" \(number($0.value))" }.joined(separator: ", ") + ";"
    }

    /// 滑块的值限在轴的范围里。
    static func clamp(_ value: Double, _ axis: FontAxisInfo) -> Double {
        min(max(value, axis.minValue), axis.maxValue)
    }

    /// 现在的值是哪个命名样式（每根轴都差不多一样）。
    static func matchingInstance(_ values: [Double], in instances: [FontNamedInstance]) -> Int? {
        instances.firstIndex { instance in
            instance.coordinates.count == values.count && zip(instance.coordinates, values).allSatisfy { abs($0 - $1) < 0.5 }
        }
    }
}

// MARK: name 表

enum FontNameTable {
    /// 读 name 表，每个编号挑一个最合适的语言：中文界面优先简体中文，其次英文，再其次随便一个。
    static func parse(_ data: Data, preferChinese: Bool) -> [Int: String] {
        let r = FontTableReader(data)
        guard let count = r.u16(2), let stringOffset = r.u16(4) else { return [:] }
        var best: [Int: (score: Int, text: String)] = [:]
        for i in 0..<count {
            let o = 6 + i * 12
            guard let platform = r.u16(o), let encoding = r.u16(o + 2), let language = r.u16(o + 4), let nameID = r.u16(o + 6),
                  let length = r.u16(o + 8), let offset = r.u16(o + 10) else { break }
            let start = stringOffset + offset
            guard start + length <= r.bytes.count else { continue }
            let raw = Array(r.bytes[start..<start + length])
            let text: String?
            switch platform {
            case 0, 3:
                text = String(bytes: raw, encoding: .utf16BigEndian)
            case 1 where encoding == 0:
                text = String(bytes: raw, encoding: .macOSRoman)
            default:
                text = nil
            }
            guard let text, !text.isEmpty else { continue }
            let score = Self.score(platform: platform, language: language, preferChinese: preferChinese)
            if let current = best[nameID], current.score <= score { continue }
            best[nameID] = (score, text)
        }
        return best.mapValues { $0.text }
    }

    private static func score(platform: Int, language: Int, preferChinese: Bool) -> Int {
        let chinese: Set<Int> = [0x0804, 0x1004, 0x0404, 0x0C04, 0x1404]
        switch platform {
        case 3 where chinese.contains(language): return preferChinese ? (language == 0x0804 ? 0 : 1) : 3
        case 3 where language == 0x0409: return preferChinese ? 2 : 0
        case 3: return 4
        case 0: return 5
        default: return 6
        }
    }
}

// MARK: 彩色字体调色板（CPAL）

struct FontPaletteColor: Equatable, Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

enum FontPaletteLogic {
    /// 读 CPAL 表：每个调色板一组颜色。读不出来返回空。
    static func parse(_ data: Data) -> [[FontPaletteColor]] {
        let r = FontTableReader(data)
        guard let entries = r.u16(2), let paletteCount = r.u16(4), let recordCount = r.u16(6),
              let recordsOffset = r.u32(8), entries > 0 else { return [] }
        var palettes: [[FontPaletteColor]] = []
        for p in 0..<min(paletteCount, 256) {
            guard let first = r.u16(12 + p * 2), first + entries <= recordCount else { break }
            var colors: [FontPaletteColor] = []
            for e in 0..<entries {
                let o = Int(recordsOffset) + (first + e) * 4
                guard let b = r.u8(o), let g = r.u8(o + 1), let red = r.u8(o + 2), let a = r.u8(o + 3) else { return palettes }
                colors.append(FontPaletteColor(red: red, green: g, blue: b, alpha: a))
            }
            palettes.append(colors)
        }
        return palettes
    }
}
