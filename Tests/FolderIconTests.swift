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
        let gone: Set<String> = ["/Users/me/Old", "/Volumes/Disk/X"]
        let exists: (String) -> Bool = { !gone.contains($0) }

        XCTAssertEqual(ledger.staleKey(for: "/Users/me/New", fileNumber: 42, exists: exists), "/Users/me/Old")
        // inode 只在同一个磁盘里算数
        XCTAssertNil(ledger.staleKey(for: "/Users/me/Y", fileNumber: 7, exists: exists))
        XCTAssertNil(ledger.staleKey(for: "/Users/me/New", fileNumber: 99, exists: exists))
        XCTAssertNil(ledger.staleKey(for: "/Users/me/New", fileNumber: nil, exists: exists))
        // 旧路径还在，就不是同一个文件夹被移走
        XCTAssertNil(ledger.staleKey(for: "/Users/me/New", fileNumber: 42, exists: { _ in true }))
        // 路径上本来就有记录，不用找
        XCTAssertNil(ledger.staleKey(for: "/Users/me/Old", fileNumber: 42, exists: exists))
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
