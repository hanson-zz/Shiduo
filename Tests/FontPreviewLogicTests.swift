import XCTest

/// 字体预览的纯逻辑：样张预设、字距、统一视觉大小、辅助线、列表排序、正文排版。
final class FontPreviewLogicTests: XCTestCase {

    // MARK: 样张预设

    func testPresetsAddReplaceRemoveAndRoundTrip() {
        var list = FontSamplePresets.adding(name: "品牌口号", text: "  好面包，从一块好黄油开始 ", to: [])
        XCTAssertEqual(list, [FontSamplePreset(name: "品牌口号", text: "好面包，从一块好黄油开始")], "首尾空白去掉")
        list = FontSamplePresets.adding(name: "品牌口号", text: "新句子", to: list)
        XCTAssertEqual(list.count, 1, "同名覆盖")
        XCTAssertEqual(list.first?.text, "新句子")
        XCTAssertEqual(FontSamplePresets.adding(name: "空", text: "   ", to: list), list, "空句子不存")
        let unnamed = FontSamplePresets.adding(name: "", text: "这是一句超过十二个字的很长很长的句子", to: [])
        XCTAssertEqual(unnamed.first?.name, "这是一句超过十二个字的很…", "没起名字就用句子开头")
        XCTAssertEqual(FontSamplePresets.decode(FontSamplePresets.encode(list)), list)
        XCTAssertEqual(FontSamplePresets.decode("不是 JSON"), [])
        XCTAssertEqual(FontSamplePresets.removing(name: "品牌口号", from: list), [])
    }

    func testPresetsAreCapped() {
        var list: [FontSamplePreset] = []
        for i in 0..<(FontSamplePresets.maxCustom + 5) {
            list = FontSamplePresets.adding(name: "p\(i)", text: "t\(i)", to: list)
        }
        XCTAssertEqual(list.count, FontSamplePresets.maxCustom)
        XCTAssertEqual(list.first?.name, "p5", "挤掉最早的")
    }

    func testDisplayTextFallsBackForLatinFonts() {
        XCTAssertEqual(FontSamplePresets.displayText("永和九年 Aa", coversCJK: true), "永和九年 Aa")
        XCTAssertEqual(FontSamplePresets.displayText("永和九年 Aa", coversCJK: false), "Handgloves", "英文太短：换成 Handgloves")
        XCTAssertEqual(FontSamplePresets.displayText("拾掇 永和九年 The quick brown fox 0123", coversCJK: false),
                       "The quick brown fox 0123", "留下句子里的英文部分")
        XCTAssertEqual(FontSamplePresets.displayText("Handgloves", coversCJK: false), "Handgloves")
        XCTAssertEqual(FontSamplePresets.displayText("  ", coversCJK: true), FontSamplePresets.chineseText)
        XCTAssertEqual(FontSamplePresets.displayText("", coversCJK: false), FontSamplePresets.englishText)
        XCTAssertEqual(FontSamplePresets.displayText("你好，世界！", coversCJK: false), "Handgloves", "全角标点也算中文")
    }

    // MARK: 字距

    func testTracking() {
        XCTAssertEqual(FontTracking.points(20, size: 50), 1, accuracy: 0.0001, "+20 = 千分之二十个字")
        XCTAssertEqual(FontTracking.afterMagnify(base: 0, magnification: 1.5), 100)
        XCTAssertEqual(FontTracking.afterMagnify(base: 0, magnification: 0.5), -100)
        XCTAssertEqual(FontTracking.afterMagnify(base: 380, magnification: 2), FontTracking.range.upperBound, "有上限")
        XCTAssertEqual(FontTracking.label(20), "+20")
        XCTAssertEqual(FontTracking.label(0), "0")
        XCTAssertEqual(FontTracking.label(-15), "-15")
    }

    // MARK: 统一视觉大小 / 辅助线

    func testVisualScaleUsesXHeightForLatinAndAscentForCJK() {
        // x 高只有 0.4 个字的西文字体：放大到 0.5。
        let small = FontMetricsSample(size: 100, ascent: 90, descent: 20, capHeight: 65, xHeight: 40, coversCJK: false)
        XCTAssertEqual(FontVisualSize.scale(small), 1.25, accuracy: 0.0001)
        // x 高 0.55：缩小。
        let big = FontMetricsSample(size: 100, ascent: 95, descent: 25, capHeight: 72, xHeight: 55, coversCJK: false)
        XCTAssertEqual(FontVisualSize.scale(big), 0.5 / 0.55, accuracy: 0.0001)
        // 中文看 ascent，不看 x 高。
        let cjk = FontMetricsSample(size: 100, ascent: 80, descent: 20, capHeight: 0, xHeight: 52, coversCJK: true)
        XCTAssertEqual(FontVisualSize.scale(cjk), 0.88 / 0.8, accuracy: 0.0001)
        // 没写 x 高：用大写高。
        let noX = FontMetricsSample(size: 100, ascent: 90, descent: 20, capHeight: 56, xHeight: 0, coversCJK: false)
        XCTAssertEqual(FontVisualSize.scale(noX), 1.25, accuracy: 0.0001)
        // 什么都没有 / 读错的数据：不缩放，或者限在范围里。
        XCTAssertEqual(FontVisualSize.scale(FontMetricsSample(size: 100, ascent: 0, descent: 0, capHeight: 0, xHeight: 0, coversCJK: false)), 1)
        XCTAssertEqual(FontVisualSize.scale(FontMetricsSample(size: 100, ascent: 90, descent: 20, capHeight: 70, xHeight: 10, coversCJK: false)),
                       FontVisualSize.scaleRange.upperBound)
        XCTAssertEqual(FontVisualSize.scale(FontMetricsSample(size: 0, ascent: 1, descent: 1, capHeight: 1, xHeight: 1, coversCJK: false)), 1)
    }

    func testGuides() {
        let m = FontMetricsSample(size: 100, ascent: 90, descent: 20, capHeight: 70, xHeight: 50, coversCJK: false)
        XCTAssertEqual(FontGuides.lines(m).map(\.kind), [.baseline, .xHeight, .capHeight])
        XCTAssertEqual(FontGuides.lines(m).map(\.offset), [0, 50, 70])
        let noX = FontMetricsSample(size: 100, ascent: 90, descent: 20, capHeight: 70, xHeight: 0, coversCJK: false)
        XCTAssertEqual(FontGuides.lines(noX).map(\.kind), [.baseline, .capHeight], "没有 x 高不画")
        let same = FontMetricsSample(size: 100, ascent: 90, descent: 20, capHeight: 70, xHeight: 70, coversCJK: false)
        XCTAssertEqual(FontGuides.lines(same).count, 2, "重合的线只画一条")
        XCTAssertEqual(FontGuides.baselineY(height: 100, ascent: 60, descent: 20), 30, "一行字竖直居中")
    }

    // MARK: 列表

    private func family(_ name: String, styles: Int = 1, version: String = "", bytes: Int64 = 10, added: Date? = nil,
                        format: FontFileFormat = .otf) -> FontFamily {
        let faces = (0..<styles).map { i in
            FontFace(postScriptName: "\(name)-\(i)", family: name, localizedFamily: "", style: i == 0 ? "Regular" : "S\(i)",
                     version: version, path: "/f/\(name)-\(i).\(format.rawValue)", fileSize: bytes, format: format,
                     isVariable: false, location: .user, added: added, modified: nil, coversCJK: false)
        }
        return FontFamily(name: name, displayName: name, faces: faces)
    }

    func testListRow() {
        let row = FontListLogic.row(family("Brand", styles: 2, version: "Version 1.00;PS 1.0", bytes: 5),
                                    extra: FontExtraInfo(manufacturer: "URW", designer: "Frutiger", glyphCount: 855), license: "可商用")
        XCTAssertEqual(row.version, "1.00", "保留原来的写法")
        XCTAssertEqual(row.versionKey, Decimal(1))
        XCTAssertEqual(row.styleCount, 2)
        XCTAssertEqual(row.manufacturer, "URW")
        XCTAssertEqual(row.glyphCount, 855)
        XCTAssertEqual(row.bytes, 10)
        XCTAssertEqual(row.format, "OTF")
        let noExtra = FontListLogic.row(family("X", version: "beta"), extra: nil, license: "")
        XCTAssertEqual(noExtra.version, "beta")
        XCTAssertEqual(noExtra.versionKey, -1)
        XCTAssertEqual(noExtra.manufacturer, "")
    }

    func testListSorting() {
        let rows = [
            FontListLogic.row(family("B", styles: 4, version: "1.1"), extra: FontExtraInfo(glyphCount: 10), license: ""),
            FontListLogic.row(family("A", styles: 1, version: "1.002"), extra: FontExtraInfo(glyphCount: 30), license: ""),
            FontListLogic.row(family("C", styles: 4, version: "2.0"), extra: FontExtraInfo(glyphCount: 20), license: ""),
        ]
        XCTAssertEqual(FontListLogic.sorted(rows, by: .default).map(\.name), ["A", "B", "C"])
        XCTAssertEqual(FontListLogic.sorted(rows, by: FontListSort(column: .version, ascending: false)).map(\.name), ["C", "B", "A"],
                       "版本按数字比：1.1 比 1.002 新")
        XCTAssertEqual(FontListLogic.sorted(rows, by: FontListSort(column: .glyphs, ascending: true)).map(\.name), ["B", "C", "A"])
        XCTAssertEqual(FontListLogic.sorted(rows, by: FontListSort(column: .styles, ascending: false)).map(\.name), ["B", "C", "A"],
                       "一样多时按名字")
    }

    func testListSortPersistenceAndHeaderMapping() {
        let sort = FontListSort(column: .version, ascending: false)
        XCTAssertEqual(sort.rawValue, "version:desc")
        XCTAssertEqual(FontListSort(rawValue: "version:desc"), sort)
        XCTAssertNil(FontListSort(rawValue: "nope:asc"))
        XCTAssertNil(FontListSort(rawValue: "name"))
        for column in FontListColumn.allCases {
            XCTAssertEqual(FontListLogic.column(for: FontListLogic.keyPath(column)), column)
            let comparator = FontListLogic.comparator(FontListSort(column: column, ascending: true))
            XCTAssertEqual(FontListLogic.sort(from: [comparator], current: .default), FontListSort(column: column, ascending: true))
        }
        let reverse = FontListLogic.comparator(sort)
        XCTAssertEqual(FontListLogic.sort(from: [reverse], current: .default), sort)
        XCTAssertEqual(FontListLogic.sort(from: [], current: sort), sort, "认不出就不变")
    }

    func testVersionNumberText() {
        XCTAssertEqual(FontVersion.number("Version 2.002;hotconv"), "2.002")
        XCTAssertEqual(FontVersion.number("1.00"), "1.00")
        XCTAssertNil(FontVersion.number("Version x"))
    }

    // MARK: 正文排版

    func testBodyPresets() {
        let book = FontBodyLogic.preset(.book, cjk: true)
        XCTAssertEqual(book.columns, 1)
        XCTAssertTrue(FontBodyLogic.paragraphs(book.body).allSatisfy { $0.hasPrefix("\u{3000}\u{3000}") }, "中文书籍段首缩进两个字")
        XCTAssertEqual(FontBodyLogic.preset(.magazine, cjk: true).columns, 2)
        XCTAssertEqual(FontBodyLogic.preset(.magazine, cjk: true).title, FontBodyLogic.zhTitle)
        XCTAssertEqual(FontBodyLogic.preset(.web, cjk: false).title, FontBodyLogic.enTitle, "西文字体用英文稿")
        XCTAssertFalse(FontBodyLogic.paragraphs(FontBodyLogic.preset(.book, cjk: false).body).first?.hasPrefix("\u{3000}") ?? true)
    }

    func testParagraphsAndColumns() {
        XCTAssertEqual(FontBodyLogic.paragraphs("一\n\n  二 \n\n\n三"), ["一", "二", "三"])
        let four = ["aaaa", "bbbb", "cccc", "dddd"]
        XCTAssertEqual(FontBodyLogic.columns(four, count: 2), [["aaaa", "bbbb"], ["cccc", "dddd"]])
        XCTAssertEqual(FontBodyLogic.columns(four, count: 1), [four])
        XCTAssertEqual(FontBodyLogic.columns([], count: 2), [[], []], "总是给够栏数")
        let uneven = FontBodyLogic.columns(["a" + String(repeating: "x", count: 100), "b", "c"], count: 2)
        XCTAssertEqual(uneven, [["a" + String(repeating: "x", count: 100)], ["b", "c"]], "按字数分，长段落自己一栏")
        XCTAssertEqual(FontBodyLogic.columns(four, count: 3).flatMap { $0 }, four, "顺序不变")
    }

    func testCustomSpecimenRoundTripAndClamp() {
        var spec = FontBodyLogic.preset(.custom, cjk: true)
        spec.title = "我的标题"
        spec.bodySize = 100
        spec.columns = 9
        let decoded = FontBodyLogic.decode(FontBodyLogic.encode(spec))
        XCTAssertEqual(decoded?.title, "我的标题")
        XCTAssertEqual(decoded?.bodySize, FontBodyLogic.bodyRange.upperBound)
        XCTAssertEqual(decoded?.columns, FontBodyLogic.columnRange.upperBound)
        XCTAssertNil(FontBodyLogic.decode(""))
        XCTAssertEqual(FontBodyLogic.lineSpacing(size: 10, leading: 1.7), 5, accuracy: 0.0001)
        XCTAssertEqual(FontBodyLogic.lineSpacing(size: 10, leading: 1.0), 0, "不会是负数")
    }

    func testTitleFace() {
        func face(_ style: String) -> FontFace {
            FontFace(postScriptName: style, family: "F", localizedFamily: "", style: style, version: "", path: "/f",
                     fileSize: 1, format: .otf, isVariable: false, location: .user, added: nil, modified: nil, coversCJK: false)
        }
        XCTAssertEqual(FontBodyLogic.titleFace(in: [face("Regular"), face("Bold Italic"), face("Bold")])?.style, "Bold", "斜体不算")
        XCTAssertEqual(FontBodyLogic.titleFace(in: [face("Regular"), face("Bold"), face("SemiBold")])?.style, "SemiBold", "半粗优先")
        XCTAssertEqual(FontBodyLogic.titleFace(in: [face("常规"), face("粗体")])?.style, "粗体")
        XCTAssertNil(FontBodyLogic.titleFace(in: [face("Regular")]))
    }
}
