import XCTest

/// 可输入地址栏：路径解析、拆分、补全排序。
final class AddressBarLogicTests: XCTestCase {
    let home = "/Users/han"

    func testResolve() {
        XCTAssertEqual(AddressBarLogic.resolve("~", current: nil, home: home), home)
        XCTAssertEqual(AddressBarLogic.resolve("~/", current: nil, home: home), home)
        XCTAssertEqual(AddressBarLogic.resolve("~/文稿/工作", current: nil, home: home), "/Users/han/文稿/工作")
        XCTAssertEqual(AddressBarLogic.resolve("/Applications/", current: "/x", home: home), "/Applications")
        XCTAssertEqual(AddressBarLogic.resolve("2026/品牌", current: "/Users/han/文稿", home: home), "/Users/han/文稿/2026/品牌")
        XCTAssertEqual(AddressBarLogic.resolve("../下载", current: "/Users/han/文稿", home: home), "/Users/han/下载")
        XCTAssertEqual(AddressBarLogic.resolve("./a//b/./c", current: "/r", home: home), "/r/a/b/c")
        XCTAssertEqual(AddressBarLogic.resolve("/../..", current: nil, home: home), "/")
        XCTAssertEqual(AddressBarLogic.resolve("下载", current: nil, home: home), "/Users/han/下载", "没有当前文件夹时相对个人文件夹")
        XCTAssertNil(AddressBarLogic.resolve("   ", current: nil, home: home))
    }

    func testCleanedPastes() {
        XCTAssertEqual(AddressBarLogic.resolve("  \"/Users/han/My Files\"\n", current: nil, home: home), "/Users/han/My Files")
        XCTAssertEqual(AddressBarLogic.resolve("'~/a b'", current: nil, home: home), "/Users/han/a b")
        XCTAssertEqual(AddressBarLogic.resolve("/Users/han/My\\ Files", current: nil, home: home), "/Users/han/My Files")
        XCTAssertEqual(AddressBarLogic.resolve("file:///Users/han/%E6%96%87%E7%A8%BF", current: nil, home: home), "/Users/han/文稿")
    }

    func testDisplayPath() {
        XCTAssertEqual(AddressBarLogic.displayPath(home, home: home), "~/")
        XCTAssertEqual(AddressBarLogic.displayPath("/Users/han/文稿/工作", home: home), "~/文稿/工作/")
        XCTAssertEqual(AddressBarLogic.displayPath("/Users/hanson", home: home), "/Users/hanson/", "前缀一样但不是个人文件夹")
        XCTAssertEqual(AddressBarLogic.displayPath("/", home: home), "/")
    }

    func testSplit() {
        XCTAssertEqual(AddressBarLogic.split("~/文稿/品").directory, "~/文稿/")
        XCTAssertEqual(AddressBarLogic.split("~/文稿/品").partial, "品")
        XCTAssertEqual(AddressBarLogic.split("~/文稿/").partial, "")
        XCTAssertEqual(AddressBarLogic.split("品").directory, "")
        XCTAssertEqual(AddressBarLogic.split("~").directory, "~/")
        XCTAssertEqual(AddressBarLogic.split("/").directory, "/")
    }

    func testListingFolder() {
        XCTAssertEqual(AddressBarLogic.listingFolder(for: "~/文稿/品", current: nil, home: home), "/Users/han/文稿")
        XCTAssertEqual(AddressBarLogic.listingFolder(for: "品", current: "/Users/han/文稿", home: home), "/Users/han/文稿")
        XCTAssertEqual(AddressBarLogic.listingFolder(for: "/", current: nil, home: home), "/")
        XCTAssertEqual(AddressBarLogic.listingFolder(for: "~", current: "/x", home: home), home)
    }

    func testCompletion() {
        XCTAssertEqual(AddressBarLogic.completion(for: "~/文稿/品", picking: "品牌提案"), "~/文稿/品牌提案/")
        XCTAssertEqual(AddressBarLogic.completion(for: "", picking: "下载"), "下载/")
    }

    func testMatchKinds() {
        XCTAssertEqual(AddressBarLogic.match(name: "Downloads", partial: "downloads"), .exact)
        XCTAssertEqual(AddressBarLogic.match(name: "Downloads", partial: "DOWN"), .prefix)
        XCTAssertEqual(AddressBarLogic.match(name: "Café Photos", partial: "cafe"), .prefix, "不分重音")
        XCTAssertEqual(AddressBarLogic.match(name: "ＡＢＣ", partial: "abc"), .exact, "不分全角半角")
        XCTAssertEqual(AddressBarLogic.match(name: "品牌提案", partial: "pp"), .pinyin)
        XCTAssertEqual(AddressBarLogic.match(name: "品牌提案", partial: "pinpai"), .pinyin)
        XCTAssertEqual(AddressBarLogic.match(name: "My Projects", partial: "proj"), .contains)
        XCTAssertNil(AddressBarLogic.match(name: "品牌提案", partial: "xyz"))
        XCTAssertEqual(AddressBarLogic.match(name: "任何", partial: ""), .prefix)
    }

    func testRank() {
        let names = ["品类分析", "品牌素材（共享）", "品牌手册", "品牌提案", ".git", "合同", "照片", "Design", "design-old"]
        // 同一档里按系统的名字顺序（中文顺序随系统语言变），这里只比集合。
        XCTAssertEqual(Set(AddressBarLogic.rank(names, partial: "品牌")), ["品牌手册", "品牌素材（共享）", "品牌提案"])
        XCTAssertEqual(Set(AddressBarLogic.rank(names, partial: "品")), ["品类分析", "品牌手册", "品牌素材（共享）", "品牌提案"])
        XCTAssertEqual(AddressBarLogic.rank(names, partial: "品牌提").first, "品牌提案")
        XCTAssertEqual(AddressBarLogic.rank(names, partial: "design"), ["Design", "design-old"], "完全一样的排最前")
        XCTAssertFalse(AddressBarLogic.rank(names, partial: "").contains(".git"), "隐藏文件夹不列")
        XCTAssertEqual(AddressBarLogic.rank(names, partial: ".g"), [".git"])
        XCTAssertEqual(AddressBarLogic.rank(names, partial: "ht"), ["合同"])
        XCTAssertEqual(AddressBarLogic.rank(names, partial: "", limit: 2).count, 2)
    }
}
