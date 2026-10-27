import XCTest

/// 批量改名增强：规则依次生效、正则 $1、重名 / 非法名字、已有文件自动加 (1)、预设存取。
final class RenameEngineTests: XCTestCase {
    private func inputs(_ names: [String], dir: String = "/pics") -> [RenameInput] {
        names.map { RenameInput(name: $0, directory: dir) }
    }

    private func replace(_ find: String, _ with: String, regex: Bool = false, caseSensitive: Bool = false) -> RenameStep {
        var step = RenameStep(kind: .replace)
        step.find = find
        step.replacement = with
        step.useRegex = regex
        step.caseSensitive = caseSensitive
        return step
    }

    func testRegexCaptureThenSequence() {
        var sequence = RenameStep(kind: .sequence)
        sequence.digits = 2
        sequence.separator = "-"
        let result = RenameEngine.run(inputs(["IMG_2041.jpg", "IMG_2042.HEIC", "合影.jpg"]),
                                      steps: [replace("IMG_(\\d{4})", "活动-$1", regex: true), sequence])
        XCTAssertEqual(result.outcomes.map(\.newName), ["01-活动-2041.jpg", "02-活动-2042.HEIC", "03-合影.jpg"])
        XCTAssertNil(result.regexError)
        XCTAssertTrue(result.canApply)
    }

    func testRegexIsCaseInsensitiveByDefault() {
        let result = RenameEngine.run(inputs(["img_1.png"]), steps: [replace("IMG_(\\d)", "照片$1", regex: true)])
        XCTAssertEqual(result.outcomes[0].newName, "照片1.png")
        let strict = RenameEngine.run(inputs(["img_1.png"]), steps: [replace("IMG_(\\d)", "照片$1", regex: true, caseSensitive: true)])
        XCTAssertEqual(strict.outcomes[0].newName, "img_1.png")
        XCTAssertFalse(strict.canApply)   // 什么都没变
    }

    func testPlainReplaceIgnoresRegexCharacters() {
        let result = RenameEngine.run(inputs(["a.(1).txt"]), steps: [replace(".(1)", "_v1")])
        XCTAssertEqual(result.outcomes[0].newName, "a_v1.txt")
    }

    func testInvalidRegexBlocksApply() {
        let result = RenameEngine.run(inputs(["IMG_1.jpg"]), steps: [replace("IMG_(", "x", regex: true)])
        XCTAssertNotNil(result.regexError)
        XCTAssertEqual(result.outcomes[0].newName, "IMG_1.jpg")
        XCTAssertFalse(result.canApply)
    }

    func testDuplicatesAndIllegalNamesBlockApply() {
        let dup = RenameEngine.run(inputs(["a1.jpg", "a2.jpg"]), steps: [replace("\\d", "", regex: true)])
        XCTAssertEqual(dup.outcomes.map(\.issue), [.duplicate, .duplicate])
        XCTAssertFalse(dup.canApply)
        XCTAssertEqual(dup.problemCount, 2)

        let slash = RenameEngine.run(inputs(["a-b.jpg"]), steps: [replace("-", "/")])
        XCTAssertEqual(slash.outcomes[0].issue, .illegal)
        XCTAssertFalse(slash.canApply)

        let empty = RenameEngine.run(inputs(["abc.jpg"]), steps: [replace("abc", "")])
        XCTAssertEqual(empty.outcomes[0].issue, .illegal)

        let dot = RenameEngine.run(inputs(["abc.jpg"]), steps: [replace("abc", ".hidden")])
        XCTAssertEqual(dot.outcomes[0].issue, .illegal)

        // 不同文件夹里同名不算重名。
        let a = RenameInput(name: "x1.jpg", directory: "/a")
        let b = RenameInput(name: "x2.jpg", directory: "/b")
        let ok = RenameEngine.run([a, b], steps: [replace("\\d", "", regex: true)])
        XCTAssertEqual(ok.outcomes.map(\.issue), [nil, nil])
        XCTAssertTrue(ok.canApply)
    }

    func testExistingFileGetsNumberedSuffix() {
        let existing: [String: Set<String>] = ["/pics": ["b.jpg", "b (1).jpg", "a.jpg"]]
        let result = RenameEngine.run(inputs(["a.jpg"]), steps: [replace("a", "b")], existing: existing)
        XCTAssertEqual(result.outcomes[0].newName, "b (2).jpg")
        XCTAssertEqual(result.outcomes[0].issue, .existing)
        XCTAssertTrue(result.canApply)
    }

    func testRenamingWithinBatchIsNotAConflict() {
        // a→b、b→c：b 原来是这一批里的，不算已有文件（两步改名不会互相覆盖）。
        let existing: [String: Set<String>] = ["/pics": ["a.txt", "b.txt"]]
        var shift = RenameStep(kind: .replace)
        shift.find = "b"
        shift.replacement = "c"
        let first = replace("a", "b")
        let result = RenameEngine.run(inputs(["a.txt", "b.txt"]), steps: [shift, first], existing: existing)
        XCTAssertEqual(result.outcomes.map(\.newName), ["b.txt", "c.txt"])
        XCTAssertEqual(result.outcomes.map(\.issue), [nil, nil])
        // 只改大小写也行。
        var lower = RenameStep(kind: .letterCase)
        lower.letterCase = .lower
        let caseOnly = RenameEngine.run(inputs(["IMG.JPG"]), steps: [lower], existing: ["/pics": ["img.jpg"]])
        XCTAssertEqual(caseOnly.outcomes[0].newName, "img.JPG")
        XCTAssertNil(caseOnly.outcomes[0].issue)
    }

    func testDateSpacesCaseAndAffix() {
        let calendar = Calendar(identifier: .gregorian)
        let modified = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let shot = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 9))!
        let input = RenameInput(name: "My  Trip photo.JPG", directory: "/p", modified: modified, captured: shot)

        var date = RenameStep(kind: .date)
        date.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(RenameEngine.run([input], steps: [date]).outcomes[0].newName, "2026-10-25_My  Trip photo.JPG")

        date.dateSource = .captured
        date.position = .suffix
        date.separator = " "
        XCTAssertEqual(RenameEngine.run([input], steps: [date]).outcomes[0].newName, "My  Trip photo 2025-01-02.JPG")

        var spaces = RenameStep(kind: .spaces)
        spaces.spaceReplacement = "_"
        var upper = RenameStep(kind: .letterCase)
        upper.letterCase = .upper
        var affix = RenameStep(kind: .affix)
        affix.prefix = "【"
        affix.suffix = "】"
        XCTAssertEqual(RenameEngine.run([input], steps: [spaces, upper, affix]).outcomes[0].newName, "【MY_TRIP_PHOTO】.JPG")
    }

    func testSequenceOptions() {
        var sequence = RenameStep(kind: .sequence)
        sequence.start = 10
        sequence.step = 5
        sequence.digits = 3
        sequence.position = .suffix
        sequence.separator = ""
        let result = RenameEngine.run(inputs(["a.txt", "b.txt"]), steps: [sequence])
        XCTAssertEqual(result.outcomes.map(\.newName), ["a010.txt", "b015.txt"])
    }

    func testRemoveCopySuffix() {
        XCTAssertEqual(RenameEngine.removeCopySuffix("报告 副本"), "报告")
        XCTAssertEqual(RenameEngine.removeCopySuffix("报告 副本 2"), "报告")
        XCTAssertEqual(RenameEngine.removeCopySuffix("报告的副本"), "报告")
        XCTAssertEqual(RenameEngine.removeCopySuffix("photo copy 3"), "photo")
        XCTAssertEqual(RenameEngine.removeCopySuffix("图 (1)"), "图")
        XCTAssertEqual(RenameEngine.removeCopySuffix("文档 2"), "文档")
        XCTAssertEqual(RenameEngine.removeCopySuffix("2024"), "2024")
        XCTAssertEqual(RenameEngine.removeCopySuffix("副本"), "副本")
        XCTAssertEqual(RenameEngine.removeCopySuffix("年报2024"), "年报2024")
    }

    func testExtensionKeptAndFoldersWhole() {
        var upper = RenameStep(kind: .letterCase)
        upper.letterCase = .upper
        let folder = RenameInput(name: "v1.2 素材", directory: "/p", isDirectory: true)
        XCTAssertEqual(RenameEngine.run([folder], steps: [upper]).outcomes[0].newName, "V1.2 素材")
        let dotfile = RenameInput(name: ".zshrc", directory: "/p")
        XCTAssertEqual(RenameEngine.splitName(dotfile.name, isDirectory: false).stem, ".zshrc")
    }

    // MARK: 预设

    func testPresetsSaveRenameDeleteAndCodable() throws {
        var list: [RenamePreset] = []
        list = RenamePresets.saving("  活动照片 ", steps: [replace("IMG", "活动")], into: list, newID: "p1")
        XCTAssertEqual(list.map(\.name), ["活动照片"])
        // 同名覆盖。
        list = RenamePresets.saving("活动照片", steps: [replace("DSC", "活动")], into: list, newID: "p2")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].steps[0].find, "DSC")
        // 空名字、没有规则不存。
        XCTAssertEqual(RenamePresets.saving(" ", steps: [replace("a", "b")], into: list).count, 1)
        XCTAssertEqual(RenamePresets.saving("x", steps: [], into: list).count, 1)

        list = RenamePresets.saving("截图", steps: [RenameStep(kind: .removeCopySuffix)], into: list, newID: "p3")
        // 改成已有的名字不行。
        XCTAssertEqual(RenamePresets.renaming("p3", to: "活动照片", in: list).map(\.name), ["活动照片", "截图"])
        list = RenamePresets.renaming("p3", to: "截图整理", in: list)
        XCTAssertEqual(list.map(\.name), ["活动照片", "截图整理"])

        let decoded = RenamePresets.decode(RenamePresets.encode(list))
        XCTAssertEqual(decoded.map(\.name), list.map(\.name))
        XCTAssertTrue(decoded[0].steps[0].sameContent(as: list[0].steps[0]))

        list = RenamePresets.deleting("p1", from: list)
        XCTAssertEqual(list.map(\.id), ["p3"])
    }

    func testOldPresetMissingFieldsDecodes() throws {
        let json = Data(#"[{"id":"x","name":"旧","steps":[{"kind":"replace","find":"a"}]}]"#.utf8)
        let list = RenamePresets.decode(json)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].steps[0].find, "a")
        XCTAssertFalse(list[0].steps[0].useRegex)   // 正则默认关
        XCTAssertEqual(list[0].steps[0].digits, 3)
        XCTAssertNil(RenamePresets.decodeSteps(Data()))
    }

    func testBuiltInPresets() {
        let presets = RenamePresets.builtIns
        XCTAssertGreaterThanOrEqual(presets.count, 6)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertTrue(presets.allSatisfy { !$0.steps.isEmpty })
        // 没有一个内置预设默认开正则。
        XCTAssertFalse(presets.flatMap(\.steps).contains { $0.useRegex })
        XCTAssertFalse(RenameStep(kind: .replace).useRegex)
        let sequence = presets.first { $0.id == "builtin.sequence" }!
        XCTAssertEqual(RenameEngine.run(inputs(["a.jpg"]), steps: sequence.steps).outcomes[0].newName, "001_a.jpg")
    }
}
