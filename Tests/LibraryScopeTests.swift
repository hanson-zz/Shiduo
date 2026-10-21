import XCTest

final class LibraryScopeTests: XCTestCase {
    let home = "/Users/me"
    var cloud: String { home + "/Library/Mobile Documents/com~apple~CloudDocs" }

    func testDefaultFoldersIncluded() {
        let scope = LibraryScope(home: home)
        XCTAssertTrue(scope.includes("/Users/me/Desktop/a.png"))
        XCTAssertTrue(scope.includes("/Users/me/Documents/报告/b.pdf"))
        XCTAssertTrue(scope.includes("/Users/me/Downloads/c.zip"))
        XCTAssertTrue(scope.includes("/Users/me/Pictures/d.jpg"))
        XCTAssertTrue(scope.includes("/Users/me/Movies/e.mov"))
        XCTAssertTrue(scope.includes("/Users/me/Music/f.mp3"))
        XCTAssertFalse(scope.includes("/Users/me/Projects/g.png"))
        XCTAssertFalse(scope.includes("/Users/me/h.png"))
        XCTAssertFalse(scope.includes("/Applications/X.app/Contents/icon.png"))
    }

    func testICloudDriveAllowedDespiteLibrary() {
        let scope = LibraryScope(home: home)
        XCTAssertTrue(scope.includes(cloud + "/设计/海报.psd"))
        XCTAssertTrue(scope.includes(cloud + "/Desktop/a.png"))
        // 其他 App 的 iCloud 容器、真正的资源库不算。
        XCTAssertFalse(scope.includes(home + "/Library/Mobile Documents/iCloud~com~foo/Documents/a.png"))
        XCTAssertFalse(scope.includes(home + "/Library/Caches/a.png"))
        // iCloud 里的隐藏文件夹仍然不算。
        XCTAssertFalse(scope.includes(cloud + "/.Trash/a.png"))
    }

    func testNoiseInsideIncludedFolders() {
        let scope = LibraryScope(home: home)
        XCTAssertFalse(scope.includes("/Users/me/Movies/My.fcpbundle/Media/a.mov"))
        XCTAssertFalse(scope.includes("/Users/me/Movies/iMovie Library.imovielibrary/a.mov"))
        XCTAssertFalse(scope.includes("/Users/me/Pictures/Photos Library.photoslibrary/originals/a.heic"))
        XCTAssertFalse(scope.includes("/Users/me/Pictures/Lightroom/Cat Previews.lrdata/a.jpg"))
        XCTAssertFalse(scope.includes("/Users/me/Documents/code/.git/objects/x"))
        XCTAssertFalse(scope.includes("/Users/me/Documents/web/node_modules/pkg/logo.png"))
        XCTAssertFalse(scope.includes("/Users/me/Downloads/Foo.app/Contents/Resources/icon.png"))
    }

    func testDisabledDefaultFolder() {
        let scope = LibraryScope(home: home, disabled: [.downloads, .desktop])
        XCTAssertFalse(scope.includes("/Users/me/Downloads/c.zip"))
        XCTAssertFalse(scope.includes("/Users/me/Desktop/a.png"))
        // 桌面存在 iCloud 里时也一起关掉。
        XCTAssertFalse(scope.includes(cloud + "/Desktop/a.png"))
        XCTAssertTrue(scope.includes(cloud + "/Other/a.png"))
        XCTAssertTrue(scope.includes("/Users/me/Documents/b.pdf"))
    }

    func testExcludedAndAddedBack() {
        var scope = LibraryScope(home: home)
        scope.exclude("/Users/me/Documents/Old/")
        XCTAssertFalse(scope.includes("/Users/me/Documents/Old/a.pdf"))
        XCTAssertTrue(scope.includes("/Users/me/Documents/Older/a.pdf"))
        XCTAssertTrue(scope.isExcludedFolder("/Users/me/Documents/Old"))
        scope.include("/Users/me/Documents/Old/Keep")
        XCTAssertTrue(scope.includes("/Users/me/Documents/Old/Keep/a.pdf"))
        XCTAssertFalse(scope.includes("/Users/me/Documents/Old/a.pdf"))
        scope.include("/Users/me/Documents/Old")
        XCTAssertTrue(scope.includes("/Users/me/Documents/Old/a.pdf"))
        XCTAssertTrue(scope.excluded.isEmpty)
    }

    func testAddedFolderOutsideDefaults() {
        var scope = LibraryScope(home: home)
        scope.include("/Users/me/Projects")
        XCTAssertEqual(scope.added, ["/Users/me/Projects"])
        XCTAssertTrue(scope.includes("/Users/me/Projects/a.png"))
        XCTAssertTrue(scope.includes("/Volumes/Disk/x.png") == false)
        // 已经在范围里的不重复加。
        scope.include("/Users/me/Documents/x")
        XCTAssertEqual(scope.added, ["/Users/me/Projects"])
    }

    func testExcludeRemovesNestedExclusions() {
        var scope = LibraryScope(home: home)
        scope.exclude("/Users/me/Documents/A/B")
        scope.exclude("/Users/me/Documents/A")
        XCTAssertEqual(scope.excluded, ["/Users/me/Documents/A"])
    }

    func testSearchRoots() {
        var scope = LibraryScope(home: home, disabled: [.music])
        scope.include("/Users/me/Projects")
        scope.include("/Users/me/Documents/Sub") // 已包含，不会加
        let existing: Set<String> = [
            "/Users/me/Desktop", "/Users/me/Documents", "/Users/me/Downloads", "/Users/me/Pictures",
            "/Users/me/Movies", "/Users/me/Music", cloud, cloud + "/Desktop", "/Users/me/Projects",
        ]
        let roots = scope.searchRoots { existing.contains($0) }
        XCTAssertFalse(roots.contains("/Users/me/Music"))
        XCTAssertTrue(roots.contains(cloud))
        XCTAssertFalse(roots.contains(cloud + "/Desktop")) // 被 iCloud 云盘包含
        XCTAssertTrue(roots.contains("/Users/me/Projects"))
        XCTAssertTrue(roots.contains("/Users/me/Desktop"))
        XCTAssertEqual(roots.count, Set(roots).count)
    }

    func testSmallImage() {
        XCTAssertTrue(LibraryScope.isSmallImage(width: 32, height: 32))
        XCTAssertFalse(LibraryScope.isSmallImage(width: 32, height: 400))
        XCTAssertFalse(LibraryScope.isSmallImage(width: nil, height: 20))
        XCTAssertFalse(LibraryScope.isSmallImage(width: 0, height: 0))
        XCTAssertFalse(LibraryScope.isSmallImage(width: 100, height: 100))
    }

    func testImageSubs() {
        typealias F = LibrarySub.Fields
        XCTAssertEqual(LibrarySub.classify(F(name: "截屏 2026.png", isScreenCapture: true), in: .images), .screenshot)
        XCTAssertEqual(LibrarySub.classify(F(name: "IMG_1.JPG", acquisitionMake: "Apple"), in: .images), .photo)
        XCTAssertEqual(LibrarySub.classify(F(name: "IMG_2.HEIC"), in: .images), .photo)
        XCTAssertEqual(LibrarySub.classify(F(name: "海报.psd"), in: .images), .design)
        XCTAssertEqual(LibrarySub.classify(F(name: "App.sketch"), in: .images), .design)
        XCTAssertEqual(LibrarySub.classify(F(name: "logo.png"), in: .images), .other)
    }

    func testVideoSubs() {
        typealias F = LibrarySub.Fields
        XCTAssertEqual(LibrarySub.classify(F(name: "屏幕录制 2026-10-01.mov"), in: .videos), .screenRecording)
        XCTAssertEqual(LibrarySub.classify(F(name: "Screen Recording 1.mov"), in: .videos), .screenRecording)
        XCTAssertEqual(LibrarySub.classify(F(name: "IMG_3.MOV", acquisitionModel: "iPhone 15"), in: .videos), .footage)
        XCTAssertEqual(LibrarySub.classify(F(name: "movie.mp4"), in: .videos), .other)
    }

    func testDocumentSubs() {
        typealias F = LibrarySub.Fields
        XCTAssertEqual(LibrarySub.classify(F(name: "a.pdf"), in: .documents), .pdf)
        XCTAssertEqual(LibrarySub.classify(F(name: "a.docx"), in: .documents), .word)
        XCTAssertEqual(LibrarySub.classify(F(name: "a.pages"), in: .documents), .word)
        XCTAssertEqual(LibrarySub.classify(F(name: "a.numbers"), in: .documents), .excel)
        XCTAssertEqual(LibrarySub.classify(F(name: "a.key"), in: .documents), .slides)
        XCTAssertEqual(LibrarySub.classify(F(name: "a.md"), in: .documents), .text)
        XCTAssertEqual(LibrarySub.classify(F(name: "a.epub"), in: .documents), .other)
        XCTAssertEqual(LibrarySub.classify(F(name: "noext", typeTree: ["public.presentation"]), in: .documents), .slides)
    }

    func testMusicSubs() {
        typealias F = LibrarySub.Fields
        XCTAssertEqual(LibrarySub.classify(F(name: "song.mp3", authors: ["周杰伦"]), in: .music), .song)
        XCTAssertEqual(LibrarySub.classify(F(name: "x.m4a", album: "Album"), in: .music), .song)
        XCTAssertEqual(LibrarySub.classify(F(name: "新录音 3.m4a"), in: .music), .recording)
        XCTAssertEqual(LibrarySub.classify(F(name: "New Recording 2.m4a"), in: .music), .recording)
        XCTAssertEqual(LibrarySub.classify(F(name: "untitled.m4a"), in: .music), .recording)
        XCTAssertEqual(LibrarySub.classify(F(name: "untitled.mp3"), in: .music), .other)
        XCTAssertEqual(LibrarySub.subs(for: .archives), [])
        XCTAssertEqual(LibrarySub.subs(for: .images).first, .photo)
    }
}
