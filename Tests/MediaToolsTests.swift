import XCTest

final class MediaToolsLogicTests: XCTestCase {
    func testKindsAndMerge() {
        XCTAssertTrue(MediaToolsLogic.isVideo(URL(fileURLWithPath: "/a/clip.MOV")))
        XCTAssertFalse(MediaToolsLogic.isVideo(URL(fileURLWithPath: "/a/clip.mkv")))
        XCTAssertTrue(MediaToolsLogic.isImage(URL(fileURLWithPath: "/a/shot.png")))
        let pdf = URL(fileURLWithPath: "/a/a.pdf")
        let png = URL(fileURLWithPath: "/a/b.png")
        let mov = URL(fileURLWithPath: "/a/c.mov")
        XCTAssertTrue(MediaToolsLogic.canMergePDF([pdf, png]))
        XCTAssertFalse(MediaToolsLogic.canMergePDF([pdf]))
        XCTAssertFalse(MediaToolsLogic.canMergePDF([pdf, mov]))
    }

    func testOutputNames() {
        let url = URL(fileURLWithPath: "/a/旅行 vlog.mov")
        XCTAssertEqual(MediaToolsLogic.outputName(for: url, suffix: "压缩", ext: "mp4"), "旅行 vlog-压缩.mp4")
        XCTAssertEqual(MediaToolsLogic.trimExtension(for: url), "mov")
        XCTAssertEqual(MediaToolsLogic.trimExtension(for: URL(fileURLWithPath: "/a/b.m4v")), "mp4")
    }

    func testClampTrim() {
        var r = MediaToolsLogic.clampTrim(start: -3, end: 99, duration: 10)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 10)
        r = MediaToolsLogic.clampTrim(start: 8, end: 2, duration: 10)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 8)
        r = MediaToolsLogic.clampTrim(start: 10, end: 10, duration: 10)
        XCTAssertEqual(r.end, 10)
        XCTAssertEqual(r.end - r.start, MediaToolsLogic.minTrimLength, accuracy: 0.0001)
        r = MediaToolsLogic.clampTrim(start: 0, end: 5, duration: 0)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 0)
    }

    func testGIFFrameTimes() {
        let times = MediaToolsLogic.gifFrameTimes(start: 0, end: 1, fps: 10)
        XCTAssertEqual(times.count, 10)
        XCTAssertEqual(times.first, 0)
        let long = MediaToolsLogic.gifFrameTimes(start: 5, end: 100, fps: 10, maxSeconds: 15)
        XCTAssertEqual(long.count, 150)
        XCTAssertLessThan(long.last ?? 0, 20)
        XCTAssertEqual(MediaToolsLogic.gifFrameTimes(start: 3, end: 3.01, fps: 10), [3])
        XCTAssertTrue(MediaToolsLogic.gifFrameTimes(start: 3, end: 2).isEmpty)
    }

    func testFitAndTimeLabel() {
        XCTAssertEqual(MediaToolsLogic.fit(CGSize(width: 1920, height: 1080), maxSide: 480), CGSize(width: 480, height: 270))
        XCTAssertEqual(MediaToolsLogic.fit(CGSize(width: 300, height: 200), maxSide: 480), CGSize(width: 300, height: 200))
        XCTAssertEqual(MediaToolsLogic.timeLabel(65.34), "1:05.3")
        XCTAssertEqual(MediaToolsLogic.timeLabel(0), "0:00.0")
    }

    func testUpscaleTiles() {
        let tiles = UpscaleLogic.tiles(width: 500, height: 224)
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles.last, CGRect(x: 448, y: 0, width: 52, height: 224))
        XCTAssertEqual(tiles.reduce(0) { $0 + Int($1.width * $1.height) }, 500 * 224)
        XCTAssertTrue(UpscaleLogic.fits(width: 2000, height: 2000, scale: 4))
        XCTAssertFalse(UpscaleLogic.fits(width: 6000, height: 4000, scale: 4))
    }

    func testPathsOrientationAndPartials() {
        XCTAssertTrue(MediaToolsLogic.isInside("/tmp/ShiduoPaste/a.png", "/tmp/ShiduoPaste"))
        XCTAssertTrue(MediaToolsLogic.isInside("/tmp/ShiduoPaste", "/tmp/ShiduoPaste/"))
        XCTAssertFalse(MediaToolsLogic.isInside("/tmp/ShiduoPaste2/a.png", "/tmp/ShiduoPaste"))
        XCTAssertFalse(MediaToolsLogic.isInside("/tmp/a.png", "/"))
        XCTAssertEqual(MediaToolsLogic.orientedSize(width: 4032, height: 3024, orientation: 6), CGSize(width: 3024, height: 4032))
        XCTAssertEqual(MediaToolsLogic.orientedSize(width: 4032, height: 3024, orientation: 3), CGSize(width: 4032, height: 3024))
        XCTAssertEqual(MediaToolsLogic.orientedSize(width: 10, height: 20, orientation: 8), CGSize(width: 20, height: 10))
        XCTAssertEqual(MediaToolsLogic.partialName(for: "旅行-压缩.mp4", token: "abc123"), ".旅行-压缩.partial-abc123.mp4")
        XCTAssertEqual(MediaToolsLogic.partialName(for: "noext", token: "x"), ".noext.partial-x")
    }

    func testBeautifyLayout() {
        var style = BeautifyStyle(background: .gradient, index: 99, padding: 0.1, corner: 0.05)
        XCTAssertEqual(style.clamped().index, BeautifyStyle.gradients.count - 1)
        var layout = style.layout(for: CGSize(width: 1000, height: 500))
        XCTAssertEqual(layout.canvas, CGSize(width: 1200, height: 700))
        XCTAssertEqual(layout.imageRect, CGRect(x: 100, y: 100, width: 1000, height: 500))
        XCTAssertEqual(layout.radius, 25)
        style.ratio = .square
        layout = style.layout(for: CGSize(width: 1000, height: 500))
        XCTAssertEqual(layout.canvas, CGSize(width: 1200, height: 1200))
        XCTAssertEqual(layout.imageRect.midY, 600)
        style.ratio = .auto
        style.frame = .dark
        layout = style.layout(for: CGSize(width: 1000, height: 500))
        XCTAssertEqual(layout.titleBar, 32)
        XCTAssertEqual(layout.windowRect.height, 532)
        XCTAssertEqual(layout.imageRect.minY, layout.windowRect.minY + 32)
        let wild = BeautifyStyle(padding: 5, corner: -1).clamped()
        XCTAssertEqual(wild.padding, BeautifyStyle.paddingRange.upperBound)
        XCTAssertEqual(wild.corner, 0)
    }
}

final class UninstallLogicTests: XCTestCase {
    func testProblems() {
        XCTAssertNil(UninstallLogic.problem(appPath: "/Applications/Foo.app", bundleID: "com.foo.app", selfBundleID: "io.github.hanson-zz.shiduo"))
        XCTAssertNotNil(UninstallLogic.problem(appPath: "/System/Applications/Notes.app", bundleID: "com.apple.Notes", selfBundleID: nil))
        XCTAssertNotNil(UninstallLogic.problem(appPath: "/Applications/Safari.app", bundleID: "com.apple.Safari", selfBundleID: nil))
        XCTAssertNotNil(UninstallLogic.problem(appPath: "/Applications/Shiduo.app", bundleID: "io.github.hanson-zz.shiduo", selfBundleID: "io.github.hanson-zz.shiduo"))
        XCTAssertNotNil(UninstallLogic.problem(appPath: "/Applications/Foo.app", bundleID: nil, selfBundleID: nil))
        XCTAssertNotNil(UninstallLogic.problem(appPath: "/Users/me/file.txt", bundleID: "com.foo", selfBundleID: nil))
    }

    func testNameBelongs() {
        let id = "com.foo.Editor"
        XCTAssertTrue(UninstallLogic.nameBelongs("com.foo.editor", bundleID: id))
        XCTAssertTrue(UninstallLogic.nameBelongs("com.foo.Editor.plist", bundleID: id))
        XCTAssertTrue(UninstallLogic.nameBelongs("com.foo.Editor.ShipIt", bundleID: id))
        XCTAssertTrue(UninstallLogic.nameBelongs("ABCDE12345.com.foo.Editor", bundleID: id))
        XCTAssertTrue(UninstallLogic.nameBelongs("group.com.foo.Editor", bundleID: id))
        XCTAssertFalse(UninstallLogic.nameBelongs("com.foo.EditorPro", bundleID: id))
        XCTAssertFalse(UninstallLogic.nameBelongs("com.foo", bundleID: id))
        XCTAssertFalse(UninstallLogic.nameBelongs("org.other.com.foo.Editor", bundleID: id))
        XCTAssertFalse(UninstallLogic.nameBelongs("abc", bundleID: "abc"))
    }

    func testMatchConfidence() {
        let id = "com.google.Chrome"
        XCTAssertEqual(UninstallLogic.match("com.google.Chrome", bundleID: id), .exact)
        XCTAssertEqual(UninstallLogic.match("com.google.Chrome.plist", bundleID: id), .exact)
        XCTAssertEqual(UninstallLogic.match("com.google.Chrome.savedState", bundleID: id), .exact)
        XCTAssertEqual(UninstallLogic.match("com.google.Chrome.0A1B2C3D-1111-2222-3333-444455556666.plist", bundleID: id), .exact)
        XCTAssertEqual(UninstallLogic.match("EQHXZ8M8AV.com.google.Chrome", bundleID: id), .exact)
        XCTAssertEqual(UninstallLogic.match("group.com.google.Chrome", bundleID: id), .exact)
        XCTAssertEqual(UninstallLogic.match("com.google.Chrome.canary", bundleID: id), .prefix)
        XCTAssertEqual(UninstallLogic.match("com.google.Chrome.canary.plist", bundleID: id), .prefix)
        XCTAssertEqual(UninstallLogic.match("group.com.google.Chrome.shared", bundleID: id), .prefix)
        // 没有点号边界的不算。
        XCTAssertNil(UninstallLogic.match("group.com.foo.application", bundleID: "com.foo.app"))
        XCTAssertNil(UninstallLogic.match("com.google.ChromeBeta", bundleID: id))
        XCTAssertNil(UninstallLogic.match("com.google", bundleID: id))
    }

    func testOtherOwner() {
        let id = "com.google.Chrome"
        XCTAssertEqual(UninstallLogic.ownerCandidates("com.google.Chrome.canary.helper.plist", bundleID: id),
                       ["com.google.Chrome.canary", "com.google.Chrome.canary.helper"])
        XCTAssertEqual(UninstallLogic.ownerCandidates("group.com.google.Chrome.beta", bundleID: id), ["com.google.Chrome.beta"])
        XCTAssertEqual(UninstallLogic.ownerCandidates("com.google.Chrome", bundleID: id), [])
        let installed = [
            "com.google.Chrome.canary": "/Applications/Google Chrome Canary.app",
            "com.google.Chrome.helper": "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app",
        ]
        let app = "/Applications/Google Chrome.app"
        XCTAssertEqual(UninstallLogic.otherOwner("com.google.Chrome.canary.plist", bundleID: id, appPath: app) { installed[$0] },
                       "/Applications/Google Chrome Canary.app")
        // 装在本 App 里面的辅助程序不算别人的。
        XCTAssertNil(UninstallLogic.otherOwner("com.google.Chrome.helper", bundleID: id, appPath: app) { installed[$0] })
        XCTAssertNil(UninstallLogic.otherOwner("com.google.Chrome.ShipIt", bundleID: id, appPath: app) { installed[$0] })
        XCTAssertTrue(UninstallLogic.isSameOrInside("/A/Foo.app/Contents", "/A/Foo.app"))
        XCTAssertFalse(UninstallLogic.isSameOrInside("/A/Foo.app2", "/A/Foo.app"))
    }

    func testOtherCopiesAndDefaultSelection() {
        let home = "/Users/me"
        let copies = UninstallLogic.otherCopies(appPath: "/Users/me/Downloads/Foo.app", all: [
            "/Users/me/Downloads/Foo.app", "/Applications/Foo.app", "/Applications/Foo.app/",
            "/Users/me/.Trash/Foo.app", "/Volumes/X/.Trashes/501/Foo.app",
        ], home: home)
        XCTAssertEqual(copies, ["/Applications/Foo.app"])
        XCTAssertTrue(UninstallLogic.otherCopies(appPath: "/Applications/Foo.app", all: ["/Applications/Foo.app"], home: home).isEmpty)

        let exact = AppLeftover(path: "/Users/me/Library/Caches/com.foo.app", kind: .caches)
        XCTAssertTrue(UninstallLogic.selectedByDefault(exact, hasOtherCopies: false))
        XCTAssertFalse(UninstallLogic.selectedByDefault(exact, hasOtherCopies: true))
        let byName = AppLeftover(path: "/Users/me/Library/Application Support/Steam", kind: .support, confidence: .name)
        XCTAssertFalse(UninstallLogic.selectedByDefault(byName, hasOtherCopies: false))
        let prefix = AppLeftover(path: "/Users/me/Library/Preferences/com.foo.app.helper.plist", kind: .preferences, confidence: .prefix)
        XCTAssertFalse(UninstallLogic.selectedByDefault(prefix, hasOtherCopies: false))
        let group = AppLeftover(path: "/Users/me/Library/Group Containers/ABC.com.foo.app", kind: .groupContainers)
        XCTAssertFalse(UninstallLogic.selectedByDefault(group, hasOtherCopies: false))
        var big = exact
        big.size = UninstallLogic.largeBytes
        XCTAssertEqual(UninstallLogic.largeItems([exact, big]).count, 1)

        let names = UninstallLogic.directCandidates(bundleID: "com.foo.app", appName: "Foo App", home: home)
        XCTAssertEqual(names.first { $0.0.hasSuffix("Application Support/Foo App") }?.2, .name)
        XCTAssertEqual(names.first { $0.0.hasSuffix("Preferences/com.foo.app.plist") }?.2, .exact)
    }

    func testDedupeKeepsBestConfidence() {
        let items = [
            AppLeftover(path: "/Users/me/Library/Application Support/Foo", kind: .support, confidence: .name),
            AppLeftover(path: "/Users/me/Library/Application Support/Foo", kind: .support, confidence: .exact),
        ]
        XCTAssertEqual(UninstallLogic.dedupe(items).map(\.confidence), [.exact])
    }

    func testCandidatesAndSafety() {
        let home = "/Users/me"
        let list = UninstallLogic.directCandidates(bundleID: "com.foo.app", appName: "Foo App", home: home).map(\.0)
        XCTAssertTrue(list.contains("/Users/me/Library/Preferences/com.foo.app.plist"))
        XCTAssertTrue(list.contains("/Users/me/Library/Application Support/Foo App"))
        let generic = UninstallLogic.directCandidates(bundleID: "com.google.x", appName: "Google", home: home).map(\.0)
        XCTAssertFalse(generic.contains("/Users/me/Library/Application Support/Google"))
        XCTAssertTrue(UninstallLogic.isSafeLeftover("/Users/me/Library/Caches/com.foo.app", home: home))
        XCTAssertFalse(UninstallLogic.isSafeLeftover("/Users/me/Library/Caches", home: home))
        XCTAssertFalse(UninstallLogic.isSafeLeftover("/Users/me/Library", home: home))
        XCTAssertFalse(UninstallLogic.isSafeLeftover("/Users/me/Documents/x", home: home))
        XCTAssertFalse(UninstallLogic.isSafeLeftover("/Users/me/Library/Caches/../../Documents", home: home))
    }

    func testDedupeKeepsParents() {
        let items = [
            AppLeftover(path: "/Users/me/Library/Containers/com.foo.app/Data", kind: .containers),
            AppLeftover(path: "/Users/me/Library/Containers/com.foo.app", kind: .containers),
            AppLeftover(path: "/Users/me/Library/Caches/com.foo.app", kind: .caches),
            AppLeftover(path: "/Users/me/Library/Caches/com.foo.app", kind: .caches),
        ]
        let result = UninstallLogic.dedupe(items)
        XCTAssertEqual(result.map(\.path), [
            "/Users/me/Library/Caches/com.foo.app",
            "/Users/me/Library/Containers/com.foo.app",
        ])
    }
}
