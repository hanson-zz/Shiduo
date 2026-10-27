import XCTest

/// 新建文件模板：起名不覆盖、{日期}、列出模板文件夹、上一次用的模板。
final class FileTemplateTests: XCTestCase {
    func testUniqueName() {
        let taken: Set<String> = ["未命名.txt", "未命名 2.txt", "素材"]
        XCTAssertEqual(FileTemplateLogic.uniqueName("未命名.txt") { taken.contains($0) }, "未命名 3.txt")
        XCTAssertEqual(FileTemplateLogic.uniqueName("未命名.md") { taken.contains($0) }, "未命名.md")
        XCTAssertEqual(FileTemplateLogic.uniqueName("素材") { taken.contains($0) }, "素材 2")
        XCTAssertEqual(FileTemplateLogic.uniqueName("报价单.tar.gz") { $0 == "报价单.tar.gz" }, "报价单.tar 2.gz")
    }

    func testExpandDate() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10))!
        XCTAssertEqual(FileTemplateLogic.expand("周报 {日期}.docx", date: date), "周报 2026-10-28.docx")
        XCTAssertEqual(FileTemplateLogic.expand("notes-{DATE}.md", date: date), "notes-2026-10-28.md")
        XCTAssertEqual(FileTemplateLogic.expand("报价单模板.xlsx", date: date), "报价单模板.xlsx")
    }

    func testVisibleTemplatesAndListing() throws {
        XCTAssertEqual(FileTemplateLogic.visibleTemplates([".DS_Store", "模板 10.md", "模板 2.md", "._x", "Icon\r"]),
                       ["模板 2.md", "模板 10.md"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(FileTemplateLogic.listTemplates(in: dir.appendingPathComponent("missing")), [])
        try Data().write(to: dir.appendingPathComponent("周报模板.docx"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("项目骨架"), withIntermediateDirectories: true)
        XCTAssertEqual(FileTemplateLogic.listTemplates(in: dir).map(\.name).sorted(), ["周报模板.docx", "项目骨架"].sorted())
    }

    func testLastChoice() {
        XCTAssertEqual(FileTemplateLogic.choice(forKey: nil, userNames: []), .builtIn(.text))
        XCTAssertEqual(FileTemplateLogic.choice(forKey: FileTemplateLogic.key(builtIn: .markdown), userNames: []), .builtIn(.markdown))
        XCTAssertEqual(FileTemplateLogic.choice(forKey: FileTemplateLogic.key(user: "周报.docx"), userNames: ["周报.docx"]), .user("周报.docx"))
        // 那个模板已经删了：退回纯文本。
        XCTAssertEqual(FileTemplateLogic.choice(forKey: "user:没了.docx", userNames: ["周报.docx"]), .builtIn(.text))
        XCTAssertEqual(FileTemplateLogic.choice(forKey: "builtin:nope", userNames: []), .builtIn(.text))
    }

    func testBuiltIns() {
        let all = BuiltInTemplate.allCases
        XCTAssertEqual(Set(all.map(\.ext)).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.fileName.hasSuffix("." + $0.ext) })
        XCTAssertEqual(all.filter(\.isExecutable), [.shell])
        XCTAssertTrue(String(decoding: BuiltInTemplate.shell.contents, as: UTF8.self).hasPrefix("#!"))
        XCTAssertTrue(String(decoding: BuiltInTemplate.html.contents, as: UTF8.self).contains("charset=\"utf-8\""))
        XCTAssertTrue(String(decoding: BuiltInTemplate.rtf.contents, as: UTF8.self).hasPrefix("{\\rtf1"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: BuiltInTemplate.json.contents))
        XCTAssertTrue(BuiltInTemplate.text.contents.isEmpty)
    }
}
