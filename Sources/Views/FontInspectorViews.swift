import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 字体细节（Pro）：字符表、OpenType 特性、可变字体 / 彩色字体调色板

// MARK: 后台读字体（字符、特性、轴、调色板、字形路径）

enum FontInspectorReader {
    static func table(_ font: CTFont, _ tag: String) -> Data? {
        CTFontCopyTable(font, CTFontTableTag(FontTag.code(tag)), []) as Data?
    }

    /// name 表（界面是中文时优先中文名字）。
    static func names(_ font: CTFont) -> [Int: String] {
        guard let data = table(font, "name") else { return [:] }
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false
        return FontNameTable.parse(data, preferChinese: chinese)
    }

    static func character(_ value: UInt32) -> String {
        Unicode.Scalar(value).map { String(Character($0)) } ?? ""
    }

    // MARK: 字符

    static func scalars(_ face: FontFace) -> [UInt32] {
        guard let font = FontPreviewFonts.font(for: face, size: 24) else { return [] }
        return FontCharsetLogic.scalars(in: CTFontCopyCharacterSet(font) as CharacterSet)
    }

    static func glyph(_ font: CTFont, _ value: UInt32) -> CGGlyph? {
        var units = Array(character(value).utf16)
        guard !units.isEmpty else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    static func hasGlyph(_ face: FontFace, _ value: UInt32) -> Bool {
        guard let font = FontPreviewFonts.font(for: face, size: 24) else { return false }
        return glyph(font, value) != nil
    }

    /// 字形轮廓导出成 SVG（按字体单位：字号 = unitsPerEm）。
    static func svg(_ face: FontFace, scalar: UInt32, title: String) -> String? {
        guard let base = FontPreviewFonts.font(for: face, size: 24) else { return nil }
        let font = CTFontCreateCopyWithAttributes(base, CGFloat(CTFontGetUnitsPerEm(base)), nil, nil)
        guard var found = glyph(font, scalar) else { return nil }
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &found, &advance, 1)
        var elements: [FontPathElement] = []
        CTFontCreatePathForGlyph(font, found, nil)?.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: elements.append(.move(element.points[0]))
            case .addLineToPoint: elements.append(.line(element.points[0]))
            case .addQuadCurveToPoint: elements.append(.quad(element.points[0], element.points[1]))
            case .addCurveToPoint: elements.append(.cubic(element.points[0], element.points[1], element.points[2]))
            case .closeSubpath: elements.append(.close)
            @unknown default: break
            }
        }
        return FontSVGLogic.svg(elements, advance: advance.width, ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), title: title)
    }

    // MARK: 特性

    struct FeatureItem: Identifiable, Sendable {
        var tag: String
        var title: String
        /// 字体自己给样式集起的名字（有的话）。
        var detail: String
        var id: String { tag }
    }

    static func features(_ face: FontFace) -> [FeatureItem] {
        guard let font = FontPreviewFonts.font(for: face, size: 24) else { return [] }
        var all: [FontLayoutFeature] = []
        for tag in ["GSUB", "GPOS"] {
            if let data = table(font, tag) { all += FontFeatureLogic.layoutFeatures(data) }
        }
        let visible = FontFeatureLogic.visible(all)
        guard !visible.isEmpty else { return [] }
        let nameTable = visible.contains { $0.uiNameID != nil } ? names(font) : [:]
        let coreText = coreTextFeatureNames(font)
        return visible.map { feature -> FeatureItem in
            let own = feature.uiNameID.flatMap { nameTable[$0] } ?? ""
            let title: String
            if let known = FontFeatureNames.title(feature.tag) {
                title = known
            } else if let n = FontFeatureLogic.variantNumber(feature.tag) {
                title = feature.tag.hasPrefix("ss") ? String(localized: "样式集 \(n)") : String(localized: "字符变体 \(n)")
            } else {
                title = coreText[feature.tag] ?? feature.tag
            }
            return FeatureItem(tag: feature.tag, title: title, detail: own)
        }
    }

    /// Core Text 给的特性名字（按 OpenType 标签），没有中文名的特性用它。
    static func coreTextFeatureNames(_ font: CTFont) -> [String: String] {
        guard let features = CTFontCopyFeatures(font) as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for feature in features {
            for selector in (feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]]) ?? [] {
                if let tag = selector[kCTFontOpenTypeFeatureTag as String] as? String,
                   let name = selector[kCTFontFeatureSelectorNameKey as String] as? String, result[tag] == nil {
                    result[tag] = name
                }
            }
        }
        return result
    }

    /// 按开关做出来的字体（只把和默认不一样的交给 Core Text）。
    static func featuredFont(_ face: FontFace, size: CGFloat, states: [String: Bool]) -> CTFont? {
        guard let base = FontPreviewFonts.font(for: face, size: size) else { return nil }
        let changes = FontFeatureLogic.changes(states)
        guard !changes.isEmpty else { return base }
        let settings: [[String: Any]] = changes.map {
            [kCTFontOpenTypeFeatureTag as String: $0.tag, kCTFontOpenTypeFeatureValue as String: $0.value]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute as String: settings] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    // MARK: 可变字体 / 调色板

    struct AxisItem: Identifiable, Sendable {
        var info: FontAxisInfo
        var title: String
        var id: String { info.tag }
    }

    struct InstanceItem: Identifiable, Sendable {
        var id: Int
        var name: String
        var values: [String: Double]
    }

    struct VariationData: Sendable {
        var axes: [AxisItem] = []
        var instances: [InstanceItem] = []
        var palettes: [[FontPaletteColor]] = []
    }

    static func variations(_ face: FontFace) -> VariationData {
        guard let font = FontPreviewFonts.font(for: face, size: 24) else { return VariationData() }
        var result = VariationData()
        var axes: [FontAxisInfo] = []
        var instances: [FontNamedInstance] = []
        if let data = table(font, "fvar"), let parsed = FontVariationLogic.parseFvar(data) {
            axes = parsed.axes
            instances = parsed.instances
        }
        // 没有 fvar（或读不出来）但 Core Text 说有轴：用 Core Text 的。
        let coreTextAxes = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
        var coreTextNames: [String: String] = [:]
        let fromFvar = !axes.isEmpty
        for axis in coreTextAxes {
            guard let id = (axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value else { continue }
            let tag = FontTag.string(id)
            coreTextNames[tag] = axis[kCTFontVariationAxisNameKey as String] as? String
            if !fromFvar,
               let lo = (axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
               let hi = (axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
               let def = (axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue {
                axes.append(FontAxisInfo(tag: tag, minValue: lo, defaultValue: def, maxValue: hi, nameID: 0, hidden: false))
            }
        }
        let nameTable = axes.isEmpty ? [:] : names(font)
        result.axes = axes.filter { !$0.hidden && $0.maxValue > $0.minValue }.map { axis in
            AxisItem(info: axis, title: FontAxisNames.title(axis.tag) ?? nameTable[axis.nameID] ?? coreTextNames[axis.tag] ?? axis.tag)
        }
        result.instances = instances.enumerated().map { index, instance -> InstanceItem in
            var values: [String: Double] = [:]
            for (axis, value) in zip(axes, instance.coordinates) { values[axis.tag] = value }
            return InstanceItem(id: index, name: nameTable[instance.nameID] ?? String(localized: "样式 \(index + 1)"), values: values)
        }
        if let data = table(font, "CPAL") { result.palettes = FontPaletteLogic.parse(data) }
        return result
    }

    /// 换调色板用的属性名。头文件里没有公开（macOS 14 起系统里有这个符号），运行时去找；找不到就只显示颜色、不能切换。
    static let paletteAttribute: CFString? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kCTFontPaletteAttribute") else { return nil }
        return symbol.assumingMemoryBound(to: CFString?.self).pointee
    }()

    /// 按轴的值和调色板做出来的字体。
    static func variedFont(_ face: FontFace, size: CGFloat, values: [String: Double], palette: Int?) -> CTFont? {
        guard let base = FontPreviewFonts.font(for: face, size: size) else { return nil }
        var attributes: [String: Any] = [:]
        if !values.isEmpty {
            var variation: [NSNumber: NSNumber] = [:]
            for (tag, value) in values { variation[NSNumber(value: FontTag.code(tag))] = NSNumber(value: value) }
            attributes[kCTFontVariationAttribute as String] = variation
        }
        if let palette, let key = paletteAttribute {
            attributes[key as String] = NSNumber(value: palette)
        }
        guard !attributes.isEmpty else { return base }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }
}

// MARK: 名字（中文 / 英文）

enum FontFeatureNames {
    static func title(_ tag: String) -> String? {
        switch tag {
        case "liga": return String(localized: "标准连字")
        case "dlig": return String(localized: "自由连字")
        case "hlig": return String(localized: "历史连字")
        case "clig": return String(localized: "上下文连字")
        case "calt": return String(localized: "上下文替代")
        case "kern": return String(localized: "字距调整")
        case "onum": return String(localized: "旧式数字")
        case "lnum": return String(localized: "齐线数字")
        case "tnum": return String(localized: "等宽数字")
        case "pnum": return String(localized: "比例数字")
        case "frac", "afrc": return String(localized: "分数")
        case "sups": return String(localized: "上标")
        case "subs", "sinf": return String(localized: "下标")
        case "ordn": return String(localized: "序数")
        case "smcp": return String(localized: "小型大写")
        case "c2sc": return String(localized: "大写转小型大写")
        case "pcap", "c2pc": return String(localized: "小写体大写")
        case "case": return String(localized: "大写适配标点")
        case "cpsp": return String(localized: "大写字距")
        case "zero": return String(localized: "斜线零")
        case "swsh", "cswh": return String(localized: "花饰字")
        case "salt": return String(localized: "风格替代")
        case "hist": return String(localized: "历史字形")
        case "titl": return String(localized: "标题字形")
        case "ornm": return String(localized: "装饰符号")
        case "trad": return String(localized: "繁体字形")
        case "smpl": return String(localized: "简体字形")
        case "fwid": return String(localized: "全角")
        case "hwid": return String(localized: "半角")
        case "pwid": return String(localized: "比例宽度")
        case "palt": return String(localized: "标点挤压（比例）")
        case "halt": return String(localized: "标点挤压（半宽）")
        case "expt": return String(localized: "专业字形")
        case "ruby": return String(localized: "注音小字")
        case "nalt": return String(localized: "带圈 / 注释字形")
        case "jp78", "jp83", "jp90", "jp04": return String(localized: "日本字形 \(String(tag.dropFirst(2)))")
        default: return nil
        }
    }
}

enum FontAxisNames {
    static func title(_ tag: String) -> String? {
        switch tag {
        case "wght": return String(localized: "字重")
        case "wdth": return String(localized: "宽度")
        case "slnt": return String(localized: "倾斜")
        case "ital": return String(localized: "斜体")
        case "opsz": return String(localized: "光学尺寸")
        default: return nil
        }
    }
}

extension FontCharCategory {
    var title: String {
        switch self {
        case .all: return String(localized: "全部")
        case .han: return String(localized: "汉字")
        case .latin: return String(localized: "拉丁")
        case .digit: return String(localized: "数字")
        case .symbol: return String(localized: "符号")
        }
    }
}

extension FontUnicodeBlock.Key {
    var title: String {
        switch self {
        case .basicLatin: return String(localized: "基本拉丁字母")
        case .latin1: return String(localized: "拉丁字母补充")
        case .latinExtA: return String(localized: "拉丁字母扩展 A")
        case .latinExtB: return String(localized: "拉丁字母扩展 B")
        case .ipa: return String(localized: "国际音标")
        case .modifiers: return String(localized: "修饰字母")
        case .combining: return String(localized: "组合附加符号")
        case .greek: return String(localized: "希腊字母")
        case .cyrillic: return String(localized: "西里尔字母")
        case .hebrew: return String(localized: "希伯来字母")
        case .arabic: return String(localized: "阿拉伯字母")
        case .thai: return String(localized: "泰文")
        case .latinExtAdditional: return String(localized: "拉丁字母扩展附加")
        case .punctuation: return String(localized: "常用标点")
        case .superSub: return String(localized: "上标和下标")
        case .currency: return String(localized: "货币符号")
        case .letterlike: return String(localized: "类字母符号")
        case .numberForms: return String(localized: "数字形式")
        case .arrows: return String(localized: "箭头")
        case .math: return String(localized: "数学运算符")
        case .technical: return String(localized: "杂项技术符号")
        case .enclosedAlnum: return String(localized: "带圈字母数字")
        case .boxDrawing: return String(localized: "制表符")
        case .shapes: return String(localized: "几何图形")
        case .miscSymbols: return String(localized: "杂项符号")
        case .dingbats: return String(localized: "装饰符号")
        case .cjkRadicals: return String(localized: "CJK 部首补充")
        case .kangxi: return String(localized: "康熙部首")
        case .cjkPunctuation: return String(localized: "CJK 符号和标点")
        case .hiragana: return String(localized: "平假名")
        case .katakana: return String(localized: "片假名")
        case .bopomofo: return String(localized: "注音符号")
        case .enclosedCJK: return String(localized: "带圈 CJK 字母和月份")
        case .cjkCompat: return String(localized: "CJK 兼容")
        case .cjkExtA: return String(localized: "CJK 统一汉字扩展 A")
        case .cjkUnified: return String(localized: "CJK 统一汉字")
        case .hangul: return String(localized: "谚文音节")
        case .privateUse: return String(localized: "私用区")
        case .cjkCompatIdeographs: return String(localized: "CJK 兼容汉字")
        case .presentationForms: return String(localized: "字母表达形式")
        case .cjkCompatForms: return String(localized: "CJK 兼容形式")
        case .fullwidth: return String(localized: "半角及全角形式")
        case .pictographs: return String(localized: "杂项符号和象形文字")
        case .emoticons: return String(localized: "表情符号")
        case .cjkExtB: return String(localized: "CJK 统一汉字扩展 B")
        case .cjkExtCF: return String(localized: "CJK 统一汉字扩展 C–F")
        case .cjkExtG: return String(localized: "CJK 统一汉字扩展 G")
        case .other: return String(localized: "其他")
        }
    }
}

// MARK: - 字符表

struct FontCharactersTab: View {
    @ObservedObject private var library = FontLibrary.shared
    let family: FontFamily
    let face: FontFace
    @State private var scalars: [UInt32] = []
    @State private var scalarSet: Set<UInt32> = []
    @State private var shown: [UInt32] = []
    @State private var loading = true
    @State private var category = FontCharCategory.all
    @State private var query = ""
    @State private var limit = FontCharsetLogic.pageSize
    @State private var selected: UInt32? = nil
    @State private var comparing = false

    var body: some View {
        let cellFont = FontPreviewFonts.swiftUIFont(face, size: 20)
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索字符 / U+ 编码：永", text: $query)
                .textFieldStyle(.roundedBorder)
            AdaptiveSegmentedPicker(title: "", selection: $category) {
                ForEach(FontCharCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .disabled(!query.isEmpty)
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if shown.isEmpty {
                Text(query.isEmpty ? LocalizedStringKey("这一类没有字符") : LocalizedStringKey("这款字体里没有这个字"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 54), spacing: 4)], spacing: 4) {
                        ForEach(shown.prefix(limit), id: \.self) { value in
                            cell(value, font: cellFont)
                        }
                    }
                    if shown.count > limit {
                        Button("再显示 \(min(FontCharsetLogic.pageSize, shown.count - limit)) 个（共 \(shown.count) 个）") {
                            limit += FontCharsetLogic.pageSize
                        }
                        .padding(.vertical, 6)
                    }
                }
                .frame(minHeight: 140, maxHeight: .infinity)
            }
            if let selected {
                detail(selected)
                if comparing { compareStrip(selected) }
            }
            Text("共 \(scalars.count) 个字符")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: face.id) { await load() }
        .onChange(of: category) { refilter() }
        .onChange(of: query) { refilter() }
    }

    private func load() async {
        loading = true
        let target = face
        let list = await Task.detached(priority: .userInitiated) { FontInspectorReader.scalars(target) }.value
        scalars = list
        scalarSet = Set(list)
        if face.coversCJK, category == .all { category = .han }
        refilter()
        // 默认选中「永」（永字八法），没有就选第一个。
        selected = scalarSet.contains(0x6C38) ? 0x6C38 : shown.first
        loading = false
    }

    private func refilter() {
        limit = FontCharsetLogic.pageSize
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            shown = FontCharsetLogic.filter(scalars, category)
        } else {
            shown = FontCharsetLogic.search(q).filter(scalarSet.contains)
            if let first = shown.first { selected = first }
        }
    }

    private func cell(_ value: UInt32, font: Font) -> some View {
        let on = selected == value
        return Text(verbatim: FontInspectorReader.character(value))
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .clipped()
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
            .onTapGesture { selected = value }
    }

    private func detail(_ value: UInt32) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: FontInspectorReader.character(value))
                .font(FontPreviewFonts.swiftUIFont(face, size: 80))
                .lineLimit(1)
                .frame(width: 120, height: 120)
                .clipped()
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: FontCharsetLogic.codeText(value))
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                Text(verbatim: FontCharsetLogic.block(value).key.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("拷贝字符") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(FontInspectorReader.character(value), forType: .string)
                }
                Button("导出 SVG…") { exportSVG(value) }
                Button(comparing ? LocalizedStringKey("收起比较") : LocalizedStringKey("和其他字体比较")) { comparing.toggle() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private struct CompareItem: Identifiable {
        let family: FontFamily
        let face: FontFace
        var id: String { family.id }
    }

    private func compareStrip(_ value: UInt32) -> some View {
        let favorites = library.families.filter { library.mark(for: $0).isFavorite }.map(\.id)
        let ids = FontCharsetLogic.compareCandidates(current: family.id, compare: library.compareIDs, favorites: favorites)
        let byID = Dictionary(library.families.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items: [CompareItem] = ids.compactMap { id in
            guard let other = byID[id], let face = other.representative, FontInspectorReader.hasGlyph(face, value) else { return nil }
            return CompareItem(family: other, face: face)
        }
        let character = FontInspectorReader.character(value)
        return VStack(alignment: .leading, spacing: 6) {
            Text("同一个字，不同字体：")
                .font(.caption)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("在字体库里把几款字体「加入对比」或「标为常用」，这里就能并排看同一个字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        VStack(spacing: 2) {
                            Text(verbatim: character).font(FontPreviewFonts.swiftUIFont(face, size: 40))
                            Text(verbatim: family.displayName).font(.caption2.weight(.semibold)).lineLimit(1).frame(maxWidth: 80)
                        }
                        ForEach(items) { item in
                            VStack(spacing: 2) {
                                Text(verbatim: character).font(FontPreviewFonts.swiftUIFont(item.face, size: 40))
                                Text(verbatim: item.family.displayName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 80)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Button("把这款加入对比") { library.addToCompare([family]) }
                .controlSize(.small)
                .disabled(library.compareIDs.contains(family.id))
        }
    }

    private func exportSVG(_ value: UInt32) {
        let name = family.displayName
        guard let svg = FontInspectorReader.svg(face, scalar: value, title: name + " " + FontCharsetLogic.codeText(value)) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = FontSVGLogic.fileName(fontName: name, scalar: value)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            LibraryStore.shared?.alertMessage = String(localized: "没能存 SVG：\(error.localizedDescription)")
        }
    }
}

// MARK: - OpenType 特性

struct FontFeaturesTab: View {
    let face: FontFace
    @State private var items: [FontInspectorReader.FeatureItem] = []
    @State private var states: [String: Bool] = [:]
    @State private var loading = true
    @State private var sample = ""

    private var firstLine: String {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "office fi 1/2 2026" : text
    }
    private var secondLine: String { face.coversCJK ? "Café № 0123 「永和九年」，岁在癸丑。" : "Café № 0123 Th ffi H₂O" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                FontLineCanvas(font: FontInspectorReader.featuredFont(face, size: 30, states: states), text: firstLine)
                    .frame(height: 52)
                FontLineCanvas(font: FontInspectorReader.featuredFont(face, size: 20, states: states), text: secondLine,
                               color: .secondaryLabelColor)
                    .frame(height: 34)
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            TextField("预览文字（不填用默认的）", text: $sample)
                .textFieldStyle(.roundedBorder)
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if items.isEmpty {
                Text("这款字体没有可以开关的 OpenType 特性。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Text("只列这款字体真的有的特性")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let css = FontFeatureLogic.css(states) {
                    Button("复制 CSS") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(css, forType: .string)
                    }
                    .help(css)
                }
                Button("恢复默认") { states = [:] }
                    .disabled(states.isEmpty)
            }
            .controlSize(.small)
        }
        .task(id: face.id) {
            loading = true
            states = [:]
            let target = face
            items = await Task.detached(priority: .userInitiated) { FontInspectorReader.features(target) }.value
            loading = false
        }
    }

    private func row(_ item: FontInspectorReader.FeatureItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                if !item.detail.isEmpty {
                    Text(verbatim: item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(verbatim: item.tag)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { states[item.tag] ?? FontFeatureLogic.isOnByDefault(item.tag) },
                set: { on in states[item.tag] = on == FontFeatureLogic.isOnByDefault(item.tag) ? nil : on }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 可变字体 / 彩色字体调色板

struct FontVariationsTab: View {
    let face: FontFace
    @State private var data = FontInspectorReader.VariationData()
    @State private var values: [String: Double] = [:]
    @State private var palette: Int? = nil
    @State private var loading = true

    private func current(_ axis: FontInspectorReader.AxisItem) -> Double {
        values[axis.info.tag] ?? axis.info.defaultValue
    }

    private var css: String {
        FontVariationLogic.css(data.axes.map { (tag: $0.info.tag, value: current($0)) })
    }

    private var selectedInstance: Int? {
        let list = data.instances.map { instance in FontNamedInstance(nameID: instance.id, coordinates: data.axes.map { instance.values[$0.info.tag] ?? $0.info.defaultValue }) }
        return FontVariationLogic.matchingInstance(data.axes.map(current), in: list).map { data.instances[$0].id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    FontLineCanvas(font: FontInspectorReader.variedFont(face, size: 52, values: values, palette: palette),
                                   text: face.coversCJK ? "Aa 字体" : "Aa Gg", centered: true)
                        .frame(height: 80)
                    FontLineCanvas(font: FontInspectorReader.variedFont(face, size: 34, values: values, palette: palette),
                                   text: "Variable", centered: true)
                        .frame(height: 50)
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    if data.axes.isEmpty {
                        Text("这款字体不是可变字体，没有可以拖的轴。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(data.axes) { axis in
                        axisRow(axis)
                    }
                    if !data.instances.isEmpty {
                        Text("命名样式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(data.instances) { instance in
                                let on = selectedInstance == instance.id
                                Button {
                                    values = instance.values
                                } label: {
                                    Text(verbatim: instance.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity)
                                        .foregroundStyle(on ? Color.white : Color.primary)
                                        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !data.axes.isEmpty {
                        Text(verbatim: css)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85)))
                        HStack {
                            Button("恢复默认") { values = [:] }
                                .disabled(values.isEmpty)
                            Spacer()
                            Button("复制 CSS") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(css, forType: .string)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.small)
                    }
                    if !data.palettes.isEmpty { paletteSection }
                }
            }
        }
        .task(id: face.id) {
            loading = true
            values = [:]
            palette = nil
            let target = face
            data = await Task.detached(priority: .userInitiated) { FontInspectorReader.variations(target) }.value
            loading = false
        }
    }

    private func axisRow(_ axis: FontInspectorReader.AxisItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: axis.title)
                Text(verbatim: axis.info.tag)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: FontVariationLogic.number(current(axis)))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            Slider(value: Binding(
                get: { current(axis) },
                set: { values[axis.info.tag] = FontVariationLogic.clamp($0, axis.info) }
            ), in: axis.info.minValue...axis.info.maxValue)
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("彩色字体：调色板")
                .font(.caption)
                .foregroundStyle(.secondary)
            if FontInspectorReader.paletteAttribute == nil {
                Text("这台 Mac 不支持切换调色板，这里只显示每套调色板的颜色。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(data.palettes.enumerated()), id: \.offset) { index, colors in
                    Button {
                        palette = index
                    } label: {
                        HStack(spacing: -4) {
                            ForEach(Array(colors.prefix(6).enumerated()), id: \.offset) { _, color in
                                Circle()
                                    .fill(Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
                                                blue: Double(color.blue) / 255, opacity: Double(color.alpha) / 255))
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                            }
                        }
                        .padding(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: (palette ?? 0) == index ? 2 : 0)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(FontInspectorReader.paletteAttribute == nil)
                    .help(String(localized: "调色板 \(index + 1)") + "：" + colors.prefix(6).map(\.hex).joined(separator: " "))
                }
            }
        }
    }
}
