import XCTest

final class FolderArtLogicTests: XCTestCase {
    private let home = "/Users/me"

    func testSpecialFolders() {
        XCTAssertEqual(FolderArtLogic.special("/Users/me", home: home), .home)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/", home: home), .home)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Desktop", home: home), .desktop)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Documents/", home: home), .documents)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Downloads", home: home), .downloads)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Pictures", home: home), .pictures)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Movies", home: home), .movies)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Music", home: home), .music)
        XCTAssertEqual(FolderArtLogic.special("/Applications", home: home), .applications)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Applications", home: home), .applications)
        XCTAssertEqual(FolderArtLogic.special("/Users/me/Library/Mobile Documents/com~apple~CloudDocs", home: home), .iCloudDrive)
    }

    func testOrdinaryFoldersAreNotSpecial() {
        XCTAssertNil(FolderArtLogic.special("/Users/me/Desktop/工作", home: home))
        XCTAssertNil(FolderArtLogic.special("/Users/me/Desktops", home: home))
        XCTAssertNil(FolderArtLogic.special("/Users/other/Desktop", home: home))
        XCTAssertNil(FolderArtLogic.special("/", home: home))
        XCTAssertNil(FolderArtLogic.special("/Users/me/Desktop", home: "/"))
    }

    func testEverySpecialHasSymbol() {
        for special in FolderArtLogic.Special.allCases {
            XCTAssertFalse(special.symbol.isEmpty)
        }
    }

    func testCustomIconFlag() {
        var info = [UInt8](repeating: 0, count: 32)
        XCTAssertFalse(FolderArtLogic.hasCustomIconFlag(info))
        info[8] = 0x04
        XCTAssertTrue(FolderArtLogic.hasCustomIconFlag(info))
        info[8] = 0x00
        info[9] = 0x04
        XCTAssertFalse(FolderArtLogic.hasCustomIconFlag(info))
        XCTAssertFalse(FolderArtLogic.hasCustomIconFlag([0x04]))
    }

    func testPixelBuckets() {
        XCTAssertEqual(FolderArtLogic.pixelBucket(side: 16, scale: 2), 32)
        XCTAssertEqual(FolderArtLogic.pixelBucket(side: 20, scale: 2), 64)
        XCTAssertEqual(FolderArtLogic.pixelBucket(side: 64, scale: 2), 128)
        XCTAssertEqual(FolderArtLogic.pixelBucket(side: 100, scale: 2), 256)
        XCTAssertEqual(FolderArtLogic.pixelBucket(side: 220, scale: 2), 512)
        XCTAssertEqual(FolderArtLogic.pixelBucket(side: 0, scale: 0), 32)
    }

    func testCacheKey() {
        XCTAssertEqual(FolderArtLogic.cacheKey(hex: "87b3eb", pixels: 64, dark: false), "87B3EB#64#l")
        XCTAssertNotEqual(FolderArtLogic.cacheKey(hex: "87B3EB", pixels: 64, dark: true),
                          FolderArtLogic.cacheKey(hex: "87B3EB", pixels: 64, dark: false))
    }
}
