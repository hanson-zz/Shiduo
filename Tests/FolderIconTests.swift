import XCTest

final class FolderIconStyleTests: XCTestCase {
    func testCodableRoundTripForEveryOverlay() throws {
        let styles = [
            FolderIconStyle(color: "#ff8800"),
            FolderIconStyle(color: "87B3EB", overlay: .symbol("star.fill"), overlayScale: 0.5),
            FolderIconStyle(color: "EE8096", overlay: .emoji("🐼"), overlayScale: 0.3),
            FolderIconStyle(color: "4F6969", overlay: .image("/Users/me/Pictures/logo.png"), overlayScale: 0.7),
        ]
        for style in styles {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(FolderIconStyle.self, from: data)
            XCTAssertEqual(decoded, style)
        }
        XCTAssertEqual(styles[0].color, "FF8800")
    }

    func testDecodingClampsScaleAndToleratesMissingFields() throws {
        let json = #"{"color":"00ff00","overlayScale":3,"overlay":{"type":"symbol","value":"leaf.fill"}}"#
        let style = try JSONDecoder().decode(FolderIconStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.color, "00FF00")
        XCTAssertEqual(style.overlayScale, FolderIconStyle.scaleRange.upperBound)
        XCTAssertEqual(style.overlay, .symbol("leaf.fill"))

        let bare = try JSONDecoder().decode(FolderIconStyle.self, from: Data(#"{"color":"123456"}"#.utf8))
        XCTAssertEqual(bare.overlay, FolderIconStyle.Overlay.none)
        XCTAssertEqual(bare.overlayScale, FolderIconStyle.defaultScale)

        let unknown = try JSONDecoder().decode(FolderIconStyle.self, from: Data(#"{"color":"123456","overlay":{"type":"video"}}"#.utf8))
        XCTAssertEqual(unknown.overlay, FolderIconStyle.Overlay.none)
        XCTAssertNil(bare.theme)
        XCTAssertEqual(bare.hue, 0)
    }

    func testThemeRoundTripAndValidation() throws {
        let themed = FolderIconStyle(color: "87B3EB", overlay: .emoji("⭐️"), overlayScale: 0.4, theme: "animal/cat", hue: 47.6)
        XCTAssertEqual(themed.hue, 48)
        let decoded = try JSONDecoder().decode(FolderIconStyle.self, from: JSONEncoder().encode(themed))
        XCTAssertEqual(decoded, themed)
        XCTAssertEqual(decoded.theme, "animal/cat")

        XCTAssertEqual(FolderIconStyle(color: "123456", theme: "animal/cat", hue: 999).hue, 180)
        XCTAssertNil(FolderIconStyle(color: "123456", theme: "../etc/passwd").theme)
        XCTAssertNil(FolderIconStyle(color: "123456", theme: "Animal/Cat").theme)
        XCTAssertNil(FolderIconStyle(color: "123456", theme: "animal").theme)
        // 没有主题时色相没意义，固定为 0
        XCTAssertEqual(FolderIconStyle(color: "123456", hue: 90).hue, 0)
    }

    func testThemeCatalog() {
        XCTAssertEqual(FolderThemeCatalog.categories.map(\.id), ["food", "animal", "starry", "planet", "plant", "material", "building", "apple"])
        XCTAssertEqual(FolderThemeCatalog.allThemes.count, 84)
        XCTAssertEqual(Set(FolderThemeCatalog.allThemes).count, 84)
        for theme in FolderThemeCatalog.allThemes {
            XCTAssertEqual(FolderIconStyle.normalizedTheme(theme), theme)
        }
        XCTAssertEqual(FolderThemeCatalog.resourcePath("plant/monstera"), "ThemeIcons/plant/monstera.png")
        XCTAssertNil(FolderThemeCatalog.resourcePath("plant/rose"))
        XCTAssertEqual(FolderThemeCatalog.category(of: "building/eiffel")?.id, "building")
    }
}

final class FolderIconOverlayTests: XCTestCase {
    typealias P = FolderIconStyle.Point

    func testNewOverlaysDefaultToSticker() {
        XCTAssertEqual(FolderIconStyle(color: "123456", overlay: .emoji("🐼")).backdrop, .sticker)
        XCTAssertEqual(FolderIconStyle(color: "123456", overlay: .image("/a.png")).backdrop, .sticker)
        XCTAssertEqual(FolderIconStyle(color: "123456", overlay: .symbol("star.fill")).backdrop, .bare)
        XCTAssertEqual(FolderIconStyle(color: "123456", overlay: .symbol("star.fill"), theme: "animal/cat").backdrop, .disc)
        XCTAssertEqual(FolderIconStyle(color: "123456", overlay: .emoji("🐼"), theme: "animal/cat").backdrop, .sticker)
        XCTAssertNil(FolderIconStyle(color: "123456", overlay: .emoji("🐼")).overlayCenter)
    }

    func testLegacyJSONKeepsOldLook() throws {
        // 旧版本存的：没有 backdrop / overlayCenter
        let themed = try JSONDecoder().decode(FolderIconStyle.self, from: Data(
            #"{"color":"87B3EB","theme":"planet/saturn","hue":0,"overlayScale":0.4,"overlay":{"type":"emoji","value":"🤣"}}"#.utf8))
        XCTAssertEqual(themed.backdrop, .disc)
        XCTAssertNil(themed.overlayCenter)
        let plain = try JSONDecoder().decode(FolderIconStyle.self, from: Data(
            #"{"color":"87B3EB","overlayScale":0.4,"overlay":{"type":"emoji","value":"🤣"}}"#.utf8))
        XCTAssertEqual(plain.backdrop, .bare)
        XCTAssertNil(plain.overlayCenter)
        // 不认识的 backdrop、坏掉的位置也按旧样子
        let odd = try JSONDecoder().decode(FolderIconStyle.self, from: Data(
            #"{"color":"87B3EB","backdrop":"glitter","overlayCenter":{"x":"a"},"overlay":{"type":"emoji","value":"🤣"}}"#.utf8))
        XCTAssertEqual(odd.backdrop, .bare)
        XCTAssertNil(odd.overlayCenter)
    }

    func testBackdropAndCenterRoundTrip() throws {
        for backdrop in FolderIconStyle.Backdrop.allCases {
            let style = FolderIconStyle(color: "EE8096", overlay: .emoji("🐼"), overlayScale: 0.5, theme: "animal/cat",
                                        backdrop: backdrop, overlayCenter: P(x: 0.2, y: 0.3))
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(FolderIconStyle.self, from: data)
            XCTAssertEqual(decoded, style)
            XCTAssertEqual(decoded.backdrop, backdrop)
            XCTAssertEqual(decoded.overlayCenter, P(x: 0.2, y: 0.3))
        }
        let json = String(decoding: try JSONEncoder().encode(FolderIconStyle(color: "123456", overlay: .emoji("🐼"), backdrop: .bare)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""backdrop":"none""#))
        // 存进去的位置超出 0…1 时读出来夹好
        let wild = try JSONDecoder().decode(FolderIconStyle.self, from: Data(
            #"{"color":"123456","overlayCenter":{"x":3,"y":-1}}"#.utf8))
        XCTAssertEqual(wild.overlayCenter, P(x: 1, y: 0))
    }

    func testDefaultPositionsMatchOldLayout() {
        // 主题图标：右下角，离边 7%，边长 = 比例 × 0.62
        let themed = FolderIconStyle(color: "123456", overlay: .emoji("🐼"), overlayScale: 0.5, theme: "animal/cat")
        let f = themed.overlayFrame(themed: true)
        XCTAssertEqual(f.width, 0.31, accuracy: 1e-9)
        XCTAssertEqual(f.x + f.width, 0.93, accuracy: 1e-9)
        XCTAssertEqual(f.y + f.height, 0.93, accuracy: 1e-9)
        // 普通上色：水平居中，中心离底 42%
        let plain = FolderIconStyle(color: "123456", overlay: .emoji("🐼"), overlayScale: 0.4)
        let g = plain.overlayFrame(themed: false)
        XCTAssertEqual(g.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(g.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.midY, 0.58, accuracy: 1e-9)
    }

    func testCustomCenterAndClamp() {
        let style = FolderIconStyle(color: "123456", overlay: .emoji("🐼"), overlayScale: 0.4, overlayCenter: P(x: 0.3, y: 0.25))
        let f = style.overlayFrame(themed: false)
        XCTAssertEqual(f.midX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(f.midY, 0.25, accuracy: 1e-9)

        // 拖到角落外面：中心夹在画布里，最多伸出自身边长的 25%
        let corner = FolderIconStyle(color: "123456", overlay: .emoji("🐼"), overlayScale: 0.4, overlayCenter: P(x: 0, y: 1))
        let c = corner.resolvedCenter(themed: false)
        XCTAssertEqual(c.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.9, accuracy: 1e-9)
        let frame = corner.overlayFrame(themed: false)
        XCTAssertEqual(-frame.x, 0.4 * FolderIconStyle.maxOverhang, accuracy: 1e-9)
        XCTAssertLessThan(frame.x, 0)                      // 可以伸出去一点
        XCTAssertGreaterThan(frame.x + frame.width, 0)     // 但不会整个出去

        XCTAssertEqual(FolderIconStyle.clampCenter(P(x: 0.5, y: 0.5), length: 0.3), P(x: 0.5, y: 0.5))
        XCTAssertEqual(FolderIconStyle.clampCenter(P(x: 0.01, y: 0.99), length: 0), P(x: 0.01, y: 0.99))
        XCTAssertEqual(FolderIconStyle.clampCenter(P(x: 0, y: 0), length: .nan), P(x: 0, y: 0))
    }

    func testDragMovesAndClamps() {
        let start = P(x: 0.5, y: 0.5)
        let moved = FolderIconStyle.dragged(from: start, dx: 0.2, dy: -0.1, length: 0.3)
        XCTAssertEqual(moved.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 0.4, accuracy: 1e-9)
        let far = FolderIconStyle.dragged(from: start, dx: 5, dy: -5, length: 0.4)
        XCTAssertEqual(far.x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(far.y, 0.1, accuracy: 1e-9)
        let broken = FolderIconStyle.dragged(from: start, dx: .infinity, dy: .nan, length: 0.4)
        XCTAssertEqual(broken, start)
    }

    func testFrameHitTest() {
        let style = FolderIconStyle(color: "123456", overlay: .emoji("🐼"), overlayScale: 0.4, overlayCenter: P(x: 0.3, y: 0.3))
        let f = style.overlayFrame(themed: false)
        XCTAssertTrue(f.contains(P(x: 0.3, y: 0.3)))
        XCTAssertTrue(f.contains(P(x: 0.11, y: 0.49)))
        XCTAssertFalse(f.contains(P(x: 0.6, y: 0.3)))
    }
}

final class FolderIconLedgerTests: XCTestCase {
    func testHistoryDeduplicatesAndKeepsNewestFirst() {
        var ledger = FolderIconLedger()
        let a = FolderIconStyle(color: "FF0000")
        let b = FolderIconStyle(color: "00FF00", overlay: .emoji("⭐️"))
        ledger.remember(a)
        ledger.remember(b)
        ledger.remember(FolderIconStyle(color: "#ff0000"))   // 和 a 一样
        XCTAssertEqual(ledger.history, [a, b])

        for i in 0..<30 {
            ledger.remember(FolderIconStyle(color: String(format: "%06X", i)))
        }
        XCTAssertEqual(ledger.history.count, FolderIconLedger.historyLimit)
        XCTAssertEqual(ledger.history.first?.color, String(format: "%06X", 29))
        XCTAssertEqual(Set(ledger.history).count, ledger.history.count)
    }

    func testMovePathMigratesFolderAndChildren() {
        var ledger = FolderIconLedger()
        let style = FolderIconStyle(color: "AABBCC")
        ledger.recordApplied(style, path: "/Users/me/Projects", hadCustomIcon: true, backupFile: "abc.icns")
        ledger.recordApplied(style, path: "/Users/me/Projects/App", hadCustomIcon: false, backupFile: nil)
        ledger.recordApplied(style, path: "/Users/me/Projects2", hadCustomIcon: false, backupFile: nil)

        ledger.movePath("/Users/me/Projects", to: "/Volumes/Disk/Work")

        XCTAssertNil(ledger.folders["/Users/me/Projects"])
        XCTAssertNil(ledger.folders["/Users/me/Projects/App"])
        XCTAssertEqual(ledger.folders["/Volumes/Disk/Work"]?.backupFile, "abc.icns")
        XCTAssertEqual(ledger.folders["/Volumes/Disk/Work"]?.hadCustomIcon, true)
        XCTAssertNotNil(ledger.folders["/Volumes/Disk/Work/App"])
        // 名字只是前缀相同的文件夹不能跟着动
        XCTAssertNotNil(ledger.folders["/Users/me/Projects2"])
        XCTAssertEqual(ledger.folders.count, 3)
    }

    func testReapplyKeepsOriginalState() {
        var ledger = FolderIconLedger()
        ledger.recordApplied(FolderIconStyle(color: "111111"), path: "/a", hadCustomIcon: true, backupFile: "orig.icns")
        ledger.recordApplied(FolderIconStyle(color: "222222"), path: "/a", hadCustomIcon: false, backupFile: nil)
        XCTAssertEqual(ledger.folders["/a"]?.style.color, "222222")
        XCTAssertEqual(ledger.folders["/a"]?.hadCustomIcon, true)
        XCTAssertEqual(ledger.folders["/a"]?.backupFile, "orig.icns")
    }

    func testStaleKeyFindsFolderMovedOutsideShiduo() {
        var ledger = FolderIconLedger()
        ledger.recordApplied(FolderIconStyle(color: "111111"), path: "/Users/me/Old", hadCustomIcon: false, backupFile: nil, fileNumber: 42)
        ledger.recordApplied(FolderIconStyle(color: "222222"), path: "/Volumes/Disk/X", hadCustomIcon: false, backupFile: nil, fileNumber: 7)
        let gone: (String) -> UInt64? = { _ in nil }

        XCTAssertEqual(ledger.staleKey(for: "/Users/me/New", fileNumber: 42, inodeAt: gone), "/Users/me/Old")
        // inode 只在同一个磁盘里算数
        XCTAssertNil(ledger.staleKey(for: "/Users/me/Y", fileNumber: 7, inodeAt: gone))
        XCTAssertNil(ledger.staleKey(for: "/Users/me/New", fileNumber: 99, inodeAt: gone))
        XCTAssertNil(ledger.staleKey(for: "/Users/me/New", fileNumber: nil, inodeAt: gone))
        // 旧路径上还是同一个文件夹（inode 一样），就不是被移走
        XCTAssertNil(ledger.staleKey(for: "/Users/me/New", fileNumber: 42, inodeAt: { _ in 42 }))
        // 旧路径上已经是别的文件夹了（inode 不一样），记录照样能找回
        XCTAssertEqual(ledger.staleKey(for: "/Users/me/New", fileNumber: 42, inodeAt: { _ in 500 }), "/Users/me/Old")
        // 路径上本来就有、而且是它自己的记录
        XCTAssertEqual(ledger.ownerKey(for: "/Users/me/Old", fileNumber: 42, inodeAt: gone), "/Users/me/Old")
    }

    /// 给 /x 上色 → 在访达里改名成 /y → 新建一个文件夹 /x。
    func testPathReusedByAnotherFolder() {
        var ledger = FolderIconLedger()
        ledger.recordApplied(FolderIconStyle(color: "111111"), path: "/Users/me/x", hadCustomIcon: true,
                             backupFile: "A.icns", fileNumber: 42)
        // 现在磁盘上：/Users/me/x 是新文件夹（inode 99），/Users/me/y 是原来那个（inode 42）
        let disk: [String: UInt64] = ["/Users/me/x": 99, "/Users/me/y": 42]
        let inodeAt: (String) -> UInt64? = { disk[$0] }

        // 新的 /x 不算上过色：不给「还原」，不会把旧文件夹的原图标贴上去
        XCTAssertNil(ledger.ownerKey(for: "/Users/me/x", fileNumber: 99, inodeAt: inodeAt))
        // /y 能按 inode 找回自己的记录
        XCTAssertEqual(ledger.ownerKey(for: "/Users/me/y", fileNumber: 42, inodeAt: inodeAt), "/Users/me/x")

        // 给新的 /x 上色：占着路径的旧记录挪去孤儿位，路径空出来，新文件夹会备份它自己的原图标
        ledger.claim("/Users/me/x", fileNumber: 99, inodeAt: inodeAt, orphanID: "o1")
        XCTAssertNil(ledger.folders["/Users/me/x"])
        let orphan = FolderIconLedger.orphanKey("/Users/me/x", id: "o1")
        XCTAssertTrue(FolderIconLedger.isOrphanKey(orphan))
        XCTAssertEqual(ledger.folders[orphan]?.backupFile, "A.icns")
        ledger.recordApplied(FolderIconStyle(color: "222222"), path: "/Users/me/x", hadCustomIcon: true,
                             backupFile: "B.icns", fileNumber: 99)

        // 之后在 /y 上操作：认领孤儿记录，拿回的是自己的备份
        XCTAssertEqual(ledger.ownerKey(for: "/Users/me/y", fileNumber: 42, inodeAt: inodeAt), orphan)
        ledger.claim("/Users/me/y", fileNumber: 42, inodeAt: inodeAt)
        XCTAssertEqual(ledger.folders["/Users/me/y"]?.backupFile, "A.icns")
        XCTAssertEqual(ledger.folders["/Users/me/x"]?.backupFile, "B.icns")
        XCTAssertNil(ledger.folders[orphan])
        XCTAssertEqual(ledger.folders.count, 2)
    }

    func testOrphanKeyKeepsVolumeAndIsNotAChild() {
        let orphan = FolderIconLedger.orphanKey("/Volumes/Disk/x", id: "o")
        XCTAssertEqual(FolderIconLedger.volumeRoot(orphan), "/Volumes/Disk")
        var ledger = FolderIconLedger()
        ledger.folders[orphan] = FolderIconRecord(style: FolderIconStyle(color: "111111"), hadCustomIcon: false,
                                                  backupFile: nil, date: Date(), fileNumber: 1)
        ledger.movePath("/Volumes/Disk/x", to: "/Volumes/Disk/z")
        XCTAssertNotNil(ledger.folders[orphan])
    }

    func testOldRecordWithoutInodeStillMatchesPath() {
        var ledger = FolderIconLedger()
        ledger.recordApplied(FolderIconStyle(color: "111111"), path: "/a", hadCustomIcon: false, backupFile: nil)
        XCTAssertEqual(ledger.ownerKey(for: "/a", fileNumber: 5, inodeAt: { _ in 5 }), "/a")
        ledger.claim("/a", fileNumber: 5, inodeAt: { _ in 5 })
        XCTAssertNotNil(ledger.folders["/a"])
    }

    func testSyncHint() {
        let home = "/Users/me"
        XCTAssertEqual(FolderIconSyncHint.detect(path: "/Users/me/code/app", home: home, isGitRepo: true), .git)
        XCTAssertEqual(FolderIconSyncHint.detect(path: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/A", home: home, isGitRepo: false), .cloud)
        XCTAssertEqual(FolderIconSyncHint.detect(path: "/Users/me/Library/CloudStorage/Dropbox/A", home: home, isGitRepo: false), .cloud)
        XCTAssertEqual(FolderIconSyncHint.detect(path: "/Users/me/Dropbox", home: home, isGitRepo: false), .cloud)
        XCTAssertNil(FolderIconSyncHint.detect(path: "/Users/me/Dropboxes", home: home, isGitRepo: false))
        XCTAssertNil(FolderIconSyncHint.detect(path: "/Users/me/Projects", home: home, isGitRepo: false))
    }

    func testVolumeRoot() {
        XCTAssertEqual(FolderIconLedger.volumeRoot("/Users/me/a"), "/")
        XCTAssertEqual(FolderIconLedger.volumeRoot("/Volumes/Disk/a/b"), "/Volumes/Disk")
        XCTAssertEqual(FolderIconLedger.volumeRoot("/Volumes"), "/")
    }

    func testOldRecordWithoutFileNumberStillDecodes() throws {
        let json = #"{"folders":{"/a":{"style":{"color":"123456"},"hadCustomIcon":false,"date":0}},"history":[]}"#
        let ledger = try JSONDecoder().decode(FolderIconLedger.self, from: Data(json.utf8))
        XCTAssertNil(ledger.folders["/a"]?.fileNumber)
    }
}
