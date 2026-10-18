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
