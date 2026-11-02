import CoreGraphics
import XCTest

/// 字体细节（Pro）的纯逻辑：字符表、SVG、OpenType 特性表、fvar / name / CPAL 表、CSS。
/// 字体表用手拼的字节测（大端序），不依赖本机装了什么字体。
final class FontInspectorLogicTests: XCTestCase {

    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func fixed(_ d: Double) -> [UInt8] { be32(UInt32(bitPattern: Int32(d * 65536))) }
    private func tag(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: 字符表

    func testScalarsSkipInvisible() {
        let set = CharacterSet(charactersIn: "永A 1\n\u{1F600}\u{200B}")
        XCTAssertEqual(FontCharsetLogic.scalars(in: set), [0x31, 0x41, 0x6C38, 0x1F600], "空格、换行、零宽字符不进格子；按码位排")
    }

    func testSearch() {
        XCTAssertEqual(FontCharsetLogic.search("U+6C38"), [0x6C38])
        XCTAssertEqual(FontCharsetLogic.search("u+6c38"), [0x6C38])
        XCTAssertEqual(FontCharsetLogic.search("0x6C38"), [0x6C38])
        XCTAssertEqual(FontCharsetLogic.search(" 6C38 "), [0x6C38], "4–6 位带数字的十六进制当码位")
        XCTAssertEqual(FontCharsetLogic.search("cafe"), Array("cafe".unicodeScalars.map(\.value)), "没有数字的当普通字母")
        XCTAssertEqual(FontCharsetLogic.search("永和 永"), [0x6C38, 0x548C], "每个字一格，去重，空格不算")
        XCTAssertEqual(FontCharsetLogic.search(""), [])
        XCTAssertEqual(FontCharsetLogic.search("U+110000").first, UInt32(("U" as Unicode.Scalar).value), "超出 Unicode 的码位当普通文字")
    }

    func testCategories() {
        XCTAssertTrue(FontCharsetLogic.matches(0x6C38, .han))
        XCTAssertTrue(FontCharsetLogic.matches(0x20000, .han), "扩展 B 也算汉字")
        XCTAssertTrue(FontCharsetLogic.matches(0x41, .latin))
        XCTAssertTrue(FontCharsetLogic.matches(0xE9, .latin), "é")
        XCTAssertTrue(FontCharsetLogic.matches(0x31, .digit))
        XCTAssertTrue(FontCharsetLogic.matches(0xBD, .digit), "½")
        XCTAssertTrue(FontCharsetLogic.matches(0xA5, .symbol), "¥")
        XCTAssertTrue(FontCharsetLogic.matches(0xFF0C, .symbol), "全角逗号")
        XCTAssertFalse(FontCharsetLogic.matches(0x41, .symbol))
        XCTAssertFalse(FontCharsetLogic.matches(0x3042, .han), "平假名不是汉字")
        XCTAssertTrue(FontCharsetLogic.matches(0x3042, .all))
        XCTAssertEqual(FontCharsetLogic.filter([0x41, 0x6C38, 0x31], .han), [0x6C38])
        XCTAssertEqual(FontCharsetLogic.filter([0x41, 0x6C38], .all), [0x41, 0x6C38])
    }

    func testCodeTextAndBlocks() {
        XCTAssertEqual(FontCharsetLogic.codeText(0x6C38), "U+6C38")
        XCTAssertEqual(FontCharsetLogic.codeText(0x41), "U+0041")
        XCTAssertEqual(FontCharsetLogic.codeText(0x1F600), "U+1F600")
        XCTAssertEqual(FontCharsetLogic.block(0x6C38).key, .cjkUnified)
        XCTAssertEqual(FontCharsetLogic.block(0x41).key, .basicLatin)
        XCTAssertEqual(FontCharsetLogic.block(0x3001).key, .cjkPunctuation)
        XCTAssertEqual(FontCharsetLogic.block(0x10FFFD).key, .other)
    }

    func testCompareCandidates() {
        XCTAssertEqual(FontCharsetLogic.compareCandidates(current: "A", compare: ["B", "A", "C"], favorites: ["C", "D"], limit: 3),
                       ["B", "C", "D"], "先对比里的，再常用；去掉自己，去重")
        XCTAssertEqual(FontCharsetLogic.compareCandidates(current: "A", compare: [], favorites: []), [])
    }

    func testFourCharCodes() {
        XCTAssertEqual(FontTag.code("wght"), 0x7767_6874)
        XCTAssertEqual(FontTag.string(0x7767_6874), "wght")
        XCTAssertEqual(FontTag.code("ab"), 0x6162_2020, "不够 4 个字母补空格")
        XCTAssertEqual(FontTag.code("CPAL"), 0x4350_414C)
    }

    // MARK: SVG

    func testSVGPathFlipsY() {
        let elements: [FontPathElement] = [
            .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 100, y: 0)),
            .quad(CGPoint(x: 150, y: 50), CGPoint(x: 100, y: 100)),
            .cubic(CGPoint(x: 80, y: 120), CGPoint(x: 20, y: 120), CGPoint(x: 0, y: 100)), .close,
        ]
        XCTAssertEqual(FontSVGLogic.pathData(elements, ascent: 100), "M0 100L100 100Q150 50 100 0C80 -20 20 -20 0 0Z")
        let svg = FontSVGLogic.svg(elements, advance: 120, ascent: 100, descent: 30, title: "A&B <字>")
        XCTAssertTrue(svg.contains("viewBox=\"0 0 120 130\""))
        XCTAssertTrue(svg.contains("<title>A&amp;B &lt;字&gt;</title>"), "标题要转义")
        XCTAssertTrue(svg.hasPrefix("<?xml"))
    }

    func testSVGNumbersAndFileName() {
        XCTAssertEqual(FontSVGLogic.number(3.456), "3.46")
        XCTAssertEqual(FontSVGLogic.number(2.5), "2.5")
        XCTAssertEqual(FontSVGLogic.number(12), "12")
        XCTAssertEqual(FontSVGLogic.number(-0.004), "0")
        XCTAssertEqual(FontSVGLogic.fileName(fontName: "思源宋体", scalar: 0x6C38), "思源宋体-U+6C38.svg")
        XCTAssertEqual(FontSVGLogic.fileName(fontName: "A/B:C", scalar: 0x41), "A-B-C-U+0041.svg")
        XCTAssertEqual(FontSVGLogic.fileName(fontName: " ", scalar: 0x41), "glyph-U+0041.svg")
    }

    // MARK: OpenType 特性

    /// GSUB：4 条特性记录（liga、ss01、ccmp、liga），ss01 带 FeatureParams（名字编号 256）。
    private var gsub: Data {
        var list: [UInt8] = be16(4)
        list += tag("liga") + be16(26)
        list += tag("ss01") + be16(30)
        list += tag("ccmp") + be16(26)
        list += tag("liga") + be16(26)
        list += be16(0) + be16(0)          // 26: liga 的特性表
        list += be16(4) + be16(0)          // 30: ss01 的特性表，FeatureParams 在 +4
        list += be16(0) + be16(256)        // 34: FeatureParams：version 0，UINameID 256
        let header = be16(1) + be16(0) + be16(0) + be16(10) + be16(0)
        return Data(header + list)
    }

    func testLayoutFeatures() {
        let features = FontFeatureLogic.layoutFeatures(gsub)
        XCTAssertEqual(features.map(\.tag), ["liga", "ss01", "ccmp", "liga"])
        XCTAssertEqual(features[1].uiNameID, 256)
        XCTAssertNil(features[0].uiNameID)
        let visible = FontFeatureLogic.visible(features + [FontLayoutFeature(tag: "onum"), FontLayoutFeature(tag: "zz01")])
        XCTAssertEqual(visible.map(\.tag), ["liga", "onum", "ss01", "zz01"], "去重、去掉 ccmp，常用的在前")
        XCTAssertEqual(visible.first { $0.tag == "ss01" }?.uiNameID, 256)
        XCTAssertEqual(FontFeatureLogic.layoutFeatures(Data([0, 1])), [], "坏数据不崩")
        XCTAssertEqual(FontFeatureLogic.layoutFeatures(Data()), [])
    }

    func testFeatureChangesAndCSS() {
        let states = ["liga": false, "onum": true, "kern": true]
        let changes = FontFeatureLogic.changes(states)
        XCTAssertEqual(changes.map { $0.tag }, ["liga", "onum"], "和默认一样的不用交给 Core Text")
        XCTAssertEqual(changes.map { $0.value }, [0, 1])
        XCTAssertEqual(FontFeatureLogic.css(states), "font-feature-settings: \"liga\" 0, \"onum\" 1;")
        XCTAssertNil(FontFeatureLogic.css([:]))
        XCTAssertTrue(FontFeatureLogic.isOnByDefault("liga"))
        XCTAssertFalse(FontFeatureLogic.isOnByDefault("smcp"))
        XCTAssertEqual(FontFeatureLogic.variantNumber("ss03"), 3)
        XCTAssertEqual(FontFeatureLogic.variantNumber("cv12"), 12)
        XCTAssertNil(FontFeatureLogic.variantNumber("liga"))
    }

    // MARK: 可变字体

    private var fvar: Data {
        var bytes = be16(1) + be16(0) + be16(16) + be16(2) + be16(2) + be16(20) + be16(2) + be16(12)
        bytes += tag("wght") + fixed(100) + fixed(400) + fixed(900) + be16(0) + be16(256)
        bytes += tag("wdth") + fixed(75) + fixed(100) + fixed(100) + be16(1) + be16(257)
        bytes += be16(258) + be16(0) + fixed(700) + fixed(100)
        bytes += be16(259) + be16(0) + fixed(300) + fixed(87.5)
        return Data(bytes)
    }

    func testParseFvar() throws {
        let parsed = try XCTUnwrap(FontVariationLogic.parseFvar(fvar))
        XCTAssertEqual(parsed.axes.map(\.tag), ["wght", "wdth"])
        XCTAssertEqual(parsed.axes[0].minValue, 100)
        XCTAssertEqual(parsed.axes[0].defaultValue, 400)
        XCTAssertEqual(parsed.axes[0].maxValue, 900)
        XCTAssertEqual(parsed.axes[0].nameID, 256)
        XCTAssertFalse(parsed.axes[0].hidden)
        XCTAssertTrue(parsed.axes[1].hidden, "flags 第 1 位 = 隐藏轴")
        XCTAssertEqual(parsed.instances, [FontNamedInstance(nameID: 258, coordinates: [700, 100]),
                                          FontNamedInstance(nameID: 259, coordinates: [300, 87.5])])
        XCTAssertEqual(FontVariationLogic.matchingInstance([700, 100], in: parsed.instances), 0)
        XCTAssertNil(FontVariationLogic.matchingInstance([650, 100], in: parsed.instances))
        XCTAssertEqual(FontVariationLogic.clamp(1200, parsed.axes[0]), 900)
        XCTAssertNil(FontVariationLogic.parseFvar(Data()))
        XCTAssertNil(FontVariationLogic.parseFvar(Data(fvar.prefix(30))), "截断的表不崩")
    }

    func testVariationCSS() {
        XCTAssertEqual(FontVariationLogic.css([("wght", 600), ("wdth", 100), ("slnt", -7.5)]),
                       "font-variation-settings: \"wght\" 600, \"wdth\" 100, \"slnt\" -7.5;")
        XCTAssertEqual(FontVariationLogic.css([]), "font-variation-settings: normal;")
    }

    // MARK: name 表

    func testNameTablePrefersLanguage() {
        let weightEN = Array("Weight".utf16).flatMap { be16(Int($0)) }
        let weightZH = Array("字重".utf16).flatMap { be16(Int($0)) }
        let widthMac = Array("Width".utf8)
        let stringOffset = 6 + 3 * 12
        var bytes = be16(0) + be16(3) + be16(stringOffset)
        bytes += be16(3) + be16(1) + be16(0x0409) + be16(256) + be16(weightEN.count) + be16(0)
        bytes += be16(3) + be16(1) + be16(0x0804) + be16(256) + be16(weightZH.count) + be16(weightEN.count)
        bytes += be16(1) + be16(0) + be16(0) + be16(257) + be16(widthMac.count) + be16(weightEN.count + weightZH.count)
        bytes += weightEN + weightZH + widthMac
        let data = Data(bytes)
        XCTAssertEqual(FontNameTable.parse(data, preferChinese: true)[256], "字重")
        XCTAssertEqual(FontNameTable.parse(data, preferChinese: false)[256], "Weight")
        XCTAssertEqual(FontNameTable.parse(data, preferChinese: true)[257], "Width", "Mac 平台的 Roman 编码也能读")
        XCTAssertEqual(FontNameTable.parse(Data(), preferChinese: true), [:])
    }

    // MARK: 调色板

    func testCPAL() {
        var bytes = be16(0) + be16(2) + be16(2) + be16(4) + be32(16) + be16(0) + be16(2)
        bytes += [0, 0, 255, 255] + [255, 0, 0, 255] + [0, 255, 0, 255] + [0, 0, 0, 128]
        let palettes = FontPaletteLogic.parse(Data(bytes))
        XCTAssertEqual(palettes.count, 2)
        XCTAssertEqual(palettes[0].map(\.hex), ["#FF0000", "#0000FF"], "颜色记录是 BGRA")
        XCTAssertEqual(palettes[1].map(\.hex), ["#00FF00", "#000000"])
        XCTAssertEqual(palettes[1][1].alpha, 128)
        XCTAssertEqual(FontPaletteLogic.parse(Data([0, 0])), [])
        XCTAssertEqual(FontPaletteLogic.parse(Data(bytes.prefix(20))), [], "颜色记录被截断：不崩")
    }
}
