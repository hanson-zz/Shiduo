import CoreText
import XCTest

/// 字体管理的纯逻辑：路径安全、版本比较、重复 / 多版本 / 损坏分组、停用清单编解码、字体集绑定、中文字体判断、搜索。
final class FontLogicTests: XCTestCase {
    private let home = "/Users/designer"

    // MARK: 路径安全

    func testOnlyUserFontsCanBeDisabled() {
        XCTAssertTrue(FontPathRules.canDisable("/Users/designer/Library/Fonts/思源黑体.otf", home: home))
        XCTAssertTrue(FontPathRules.canDisable("/Users/designer/Library/Fonts/客户A/Brand-Bold.ttf", home: home))
        XCTAssertFalse(FontPathRules.canDisable("/Library/Fonts/Arial Unicode.ttf", home: home), "/Library/Fonts 要管理员权限")
        XCTAssertFalse(FontPathRules.canDisable("/System/Library/Fonts/PingFang.ttc", home: home), "系统字体永远不碰")
        XCTAssertFalse(FontPathRules.canDisable("/Users/designer/Library/Fonts", home: home), "文件夹本身不算")
        XCTAssertFalse(FontPathRules.canDisable("/Users/designer/Library/Fonts/readme.txt", home: home), "不是字体文件")
        XCTAssertFalse(FontPathRules.canDisable("/Users/designer/Library/Fonts/../Preferences/x.ttf", home: home), "不能用 .. 跳出去")
        XCTAssertFalse(FontPathRules.canDisable("/Users/designer/Library/FontsBackup/a.ttf", home: home), "前缀相同的别的文件夹不算")
        XCTAssertFalse(FontPathRules.canDisable("/Users/other/Library/Fonts/a.ttf", home: home), "别的用户的不算")
    }

    func testSystemAndAdminRules() {
        XCTAssertTrue(FontPathRules.isSystem("/System/Library/Fonts/Helvetica.ttc"))
        XCTAssertTrue(FontPathRules.isSystem("/System"))
        XCTAssertFalse(FontPathRules.isSystem("/SystemFonts/a.ttf"))
        XCTAssertTrue(FontPathRules.needsAdmin("/Library/Fonts/a.ttf"))
        XCTAssertFalse(FontPathRules.needsAdmin("/Users/designer/Library/Fonts/a.ttf"))
        XCTAssertTrue(FontPathRules.isInStore("/Users/designer/Library/Application Support/Shiduo/Fonts/Disabled/a.ttf", home: home))
        XCTAssertFalse(FontPathRules.isInStore("/Users/designer/Library/Application Support/Shiduo/Fonts/../../x", home: home))
    }

    func testRestoreTargetStaysInUserFonts() {
        XCTAssertEqual(FontPathRules.restoreTarget(originalPath: "/Users/designer/Library/Fonts/客户A/a.ttf", home: home),
                       "/Users/designer/Library/Fonts/客户A/a.ttf", "原来在 ~/Library/Fonts 里就放回原处")
        XCTAssertEqual(FontPathRules.restoreTarget(originalPath: "/Library/Fonts/b.otf", home: home),
                       "/Users/designer/Library/Fonts/b.otf", "原来不在 ~/Library/Fonts（清单被改过）就放到用户字体第一层")
        XCTAssertEqual(FontPathRules.restoreTarget(originalPath: "/System/Library/Fonts/c.ttc", home: home),
                       "/Users/designer/Library/Fonts/c.ttc", "永远不会写回系统字体文件夹")
    }

    func testUniqueName() {
        let taken: Set<String> = ["a.ttf", "a 2.ttf"]
        XCTAssertEqual(FontPathRules.uniqueName("a.ttf") { taken.contains($0) }, "a 3.ttf")
        XCTAssertEqual(FontPathRules.uniqueName("b.otf") { taken.contains($0) }, "b.otf")
    }

    // MARK: 版本

    func testVersionParsing() {
        XCTAssertEqual(FontVersion.parse("Version 1.002;PS 1.2;hotconv 1.0.88"), Decimal(string: "1.002"))
        XCTAssertEqual(FontVersion.parse("2.137"), Decimal(string: "2.137"))
        XCTAssertNil(FontVersion.parse("Version x"))
        XCTAssertEqual(FontVersion.compare("Version 1.1", "Version 1.002"), .orderedDescending, "定点小数：1.1 比 1.002 新")
        XCTAssertEqual(FontVersion.compare("Version 2.000", "2.0"), .orderedSame)
        XCTAssertTrue(FontVersion.same("Version 1.00", "Version 1.000;hotconv"))
    }

    // MARK: 重复 / 多版本 / 损坏

    private func file(_ path: String, _ location: FontLocation, ps: [String], version: String,
                      modified: TimeInterval = 0, size: Int64 = 1000) -> FontFileInfo {
        FontFileInfo(path: path, location: location, size: size, modified: Date(timeIntervalSince1970: modified),
                     postScriptNames: ps, version: version, family: "Brand")
    }

    func testDuplicatesKeepNewestUserCopy() {
        let a = file("/Users/designer/Library/Fonts/Brand.otf", .user, ps: ["Brand-Regular"], version: "Version 1.000", modified: 100)
        let b = file("/Users/designer/Library/Fonts/Brand copy.otf", .user, ps: ["Brand-Regular"], version: "1.000", modified: 200)
        let other = file("/Users/designer/Library/Fonts/Other.otf", .user, ps: ["Other"], version: "1.0")
        let groups = FontIssueLogic.issues(files: [a, b, other], damaged: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .duplicate)
        XCTAssertEqual(groups[0].keep?.path, b.path, "同版本留最新改过的")
        XCTAssertEqual(groups[0].extras.map(\.path), [a.path])
        XCTAssertEqual(groups[0].actionableBytes, 1000)
    }

    func testDuplicateKeepsLockedLocalCopy() {
        let user = file("/Users/designer/Library/Fonts/Brand.otf", .user, ps: ["Brand-Regular"], version: "1.0", modified: 300)
        let local = file("/Library/Fonts/Brand.otf", .local, ps: ["Brand-Regular"], version: "1.0", modified: 100)
        let groups = FontIssueLogic.issues(files: [user, local], damaged: [])
        XCTAssertEqual(groups.first?.keep?.path, local.path, "/Library/Fonts 里的动不了，留它，停用用户那份")
        XCTAssertEqual(groups.first?.actionableExtras.map(\.path), [user.path])
    }

    func testVersionsKeepHighest() {
        let old = file("/Users/designer/Library/Fonts/Brand-1.otf", .user, ps: ["Brand-Regular"], version: "Version 1.002", modified: 500)
        let new = file("/Users/designer/Library/Fonts/Brand-2.otf", .user, ps: ["Brand-Regular"], version: "Version 1.1", modified: 100)
        let groups = FontIssueLogic.issues(files: [old, new], damaged: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .versions)
        XCTAssertEqual(groups[0].keep?.path, new.path, "留版本最高的，不看修改时间")
        XCTAssertEqual(groups[0].extras.map(\.path), [old.path])
    }

    func testCollectionsGroupByAllNamesAndSystemIgnored() {
        // TTC：整组名字一样才算重复；只有一部分一样不算。
        let ttc1 = file("/Users/designer/Library/Fonts/Song.ttc", .user, ps: ["Song-Light", "Song-Regular"], version: "1.0")
        let ttc2 = file("/Users/designer/Library/Fonts/Song2.ttc", .user, ps: ["Song-Regular", "Song-Light"], version: "1.0")
        let partial = file("/Users/designer/Library/Fonts/SongR.ttf", .user, ps: ["Song-Regular"], version: "1.0")
        let system = file("/System/Library/Fonts/Song.ttc", .system, ps: ["Song-Light", "Song-Regular"], version: "1.0")
        let disabled = file("/Users/designer/Library/Application Support/Shiduo/Fonts/Disabled/Song.ttc", .disabled,
                            ps: ["Song-Light", "Song-Regular"], version: "1.0")
        let groups = FontIssueLogic.issues(files: [ttc1, ttc2, partial, system, disabled], damaged: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(([groups[0].keep].compactMap { $0 } + groups[0].extras).map(\.path)), [ttc1.path, ttc2.path],
                       "系统字体和已停用的不参与")
    }

    func testDamagedFonts() {
        let bad = file("/Users/designer/Library/Fonts/broken.ttf", .user, ps: [], version: "")
        let sys = file("/System/Library/Fonts/x.ttf", .system, ps: [], version: "")
        let groups = FontIssueLogic.issues(files: [], damaged: [bad, sys])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .damaged)
        XCTAssertNil(groups[0].keep)
        XCTAssertEqual(groups[0].actionableExtras.map(\.path), [bad.path])
    }

    // MARK: 停用清单

    func testManifestRoundTrip() throws {
        var manifest = FontManifest()
        let entry = FontStoreEntry(originalPath: "/Users/designer/Library/Fonts/思源宋体.otf",
                                   storedPath: "/Users/designer/Library/Application Support/Shiduo/Fonts/Disabled/思源宋体.otf",
                                   size: 24_000_000, family: "Source Han Serif SC", localizedFamily: "思源宋体",
                                   postScriptNames: ["SourceHanSerifSC-Regular"], styles: ["Regular"], version: "Version 2.001",
                                   coversCJK: true, date: Date(timeIntervalSince1970: 1_700_000_000))
        manifest.entries = [entry]
        manifest.sets = [FontSet(name: "客户A 品牌", postScriptNames: ["SourceHanSerifSC-Regular"], boundFolders: ["/Users/designer/Work/客户A"])]
        manifest.archiveFolder = "/Volumes/T7/字体"
        let data = try FontManifest.encode(manifest)
        let decoded = try XCTUnwrap(FontManifest.decode(data))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.entries.first?.fileName, "思源宋体.otf")
        XCTAssertEqual(decoded.entries.first?.location, .disabled)
        XCTAssertNil(FontManifest.decode(Data("not json".utf8)), "读不出来返回 nil，不拿空清单覆盖")
    }

    func testOrphanEntries() {
        let known = [FontStoreEntry(originalPath: "/Users/designer/Library/Fonts/a.ttf",
                                    storedPath: "/Users/designer/Library/Application Support/Shiduo/Fonts/Disabled/a.ttf",
                                    size: 1, family: "A")]
        let orphans = FontManifest.orphanEntries(
            disabledFiles: ["/Users/designer/Library/Application Support/Shiduo/Fonts/Disabled/a.ttf",
                            "/Users/designer/Library/Application Support/Shiduo/Fonts/Disabled/b.otf"],
            known: known, home: home)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.originalPath, "/Users/designer/Library/Fonts/b.otf")
    }

    // MARK: 字体集绑定

    func testSetBindingMatchesFolderAndSubfolders() {
        let a = FontSet(name: "客户A", boundFolders: ["/Users/designer/Work/客户A"])
        let b = FontSet(name: "客户B", boundFolders: ["/Users/designer/Work/客户B/"])
        XCTAssertEqual(FontSetBinding.sets(for: "/Users/designer/Work/客户A", in: [a, b]).map(\.name), ["客户A"])
        XCTAssertEqual(FontSetBinding.sets(for: "/Users/designer/Work/客户A/海报/终稿", in: [a, b]).map(\.name), ["客户A"])
        XCTAssertEqual(FontSetBinding.sets(for: "/Users/designer/Work/客户B", in: [a, b]).map(\.name), ["客户B"])
        XCTAssertTrue(FontSetBinding.sets(for: "/Users/designer/Work/客户A2", in: [a, b]).isEmpty, "名字前缀相同的别的文件夹不算")
        XCTAssertTrue(FontSetBinding.sets(for: "/Users/designer/Work", in: [a, b]).isEmpty, "上一层不算")
    }

    func testResolvePrefersInstalledCopy() {
        func face(_ ps: String, _ location: FontLocation, _ path: String) -> FontFace {
            FontFace(postScriptName: ps, family: "Brand", localizedFamily: "", style: "", version: "", path: path,
                     fileSize: 1, format: .otf, isVariable: false, location: location, added: nil, modified: nil, coversCJK: false)
        }
        let faces = [face("Brand-Bold", .archived, "/z.zip"), face("Brand-Bold", .disabled, "/d.otf"), face("Brand-Light", .user, "/u.otf")]
        let resolved = FontLibraryLogic.resolve(["Brand-Bold", "Brand-Light", "Missing"], in: faces)
        XCTAssertEqual(resolved.map(\.path), ["/d.otf", "/u.otf"])
    }

    // MARK: 中文字体

    func testCJKCoverageFromCharacterSet() {
        XCTAssertTrue(FontCoverage.coversCJK(CharacterSet(charactersIn: FontCoverage.commonHanzi)))
        XCTAssertFalse(FontCoverage.coversCJK(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz的一是")))
    }

    func testCJKCoverageWithSystemFonts() {
        // 系统界面字体本身没有汉字（靠字体回退显示），所以让 Core Text 挑一个能显示汉字的系统字体（通常是苹方）。
        let base = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let sample = "永和九年" as CFString
        let chinese = CTFontCreateForString(base, sample, CFRange(location: 0, length: CFStringGetLength(sample)))
        XCTAssertTrue(FontCoverage.coversCJK(font: chinese),
                      "能显示汉字的系统字体（\(CTFontCopyPostScriptName(chinese) as String)）包含常用汉字")
        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        XCTAssertFalse(FontCoverage.coversCJK(font: menlo), "Menlo 没有汉字")
    }

    // MARK: 搜索 / 排序

    private func family(_ name: String, _ display: String, sizes: [Int64] = [1], added: TimeInterval = 0) -> FontFamily {
        let faces = sizes.enumerated().map { index, size in
            FontFace(postScriptName: "\(name)-\(index)", family: name, localizedFamily: display, style: "", version: "",
                     path: "/f/\(name)\(index).otf", fileSize: size, format: .otf, isVariable: false, location: .user,
                     added: Date(timeIntervalSince1970: added), modified: nil, coversCJK: true)
        }
        return FontFamily(name: name, displayName: display, faces: faces)
    }

    func testSearchByChineseNamePinyinAndInitials() {
        let siyuan = family("Source Han Sans SC", "思源黑体")
        XCTAssertTrue(FontLibraryLogic.matches(siyuan, query: "思源"))
        XCTAssertTrue(FontLibraryLogic.matches(siyuan, query: "syht"), "拼音首字母")
        XCTAssertTrue(FontLibraryLogic.matches(siyuan, query: "siyuan"), "全拼")
        XCTAssertTrue(FontLibraryLogic.matches(siyuan, query: "source han"), "英文名")
        XCTAssertTrue(FontLibraryLogic.matches(siyuan, query: "Sans SC-0"), "PostScript 名字")
        XCTAssertFalse(FontLibraryLogic.matches(siyuan, query: "宋体"))
        XCTAssertFalse(FontLibraryLogic.matches(siyuan, query: "xyz"))
    }

    func testFamilyTotalsAndSorting() {
        let big = family("Big", "大字体", sizes: [10, 20], added: 10)
        let small = family("Small", "小字体", sizes: [25], added: 50)
        XCTAssertEqual(big.totalBytes, 30)
        XCTAssertEqual(big.styleCount, 2)
        XCTAssertEqual(FontLibraryLogic.sorted([small, big], by: .total).map(\.name), ["Big", "Small"])
        XCTAssertEqual(FontLibraryLogic.sorted([big, small], by: .size).map(\.name), ["Small", "Big"])
        XCTAssertEqual(FontLibraryLogic.sorted([big, small], by: .added).map(\.name), ["Small", "Big"])
    }

    func testFamiliesGroupTTCFacesOnce() {
        let faces = [
            FontFace(postScriptName: "Song-Light", family: "Song", localizedFamily: "宋", style: "Light", version: "", path: "/s.ttc",
                     fileSize: 100, format: .ttc, isVariable: false, location: .user, added: nil, modified: nil, coversCJK: true),
            FontFace(postScriptName: "Song-Regular", family: "Song", localizedFamily: "宋", style: "Regular", version: "", path: "/s.ttc",
                     fileSize: 100, format: .ttc, isVariable: false, location: .user, added: nil, modified: nil, coversCJK: true),
        ]
        let families = FontLibraryLogic.families(faces)
        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families[0].totalBytes, 100, "同一个 TTC 只算一次")
        XCTAssertEqual(families[0].representative?.style, "Regular")
        XCTAssertEqual(families[0].displayName, "宋")
    }
}
