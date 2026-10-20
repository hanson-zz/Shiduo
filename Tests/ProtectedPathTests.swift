import XCTest

final class ProtectedPathTests: XCTestCase {
    private let home = "/Users/me"

    func testProtectedFolders() {
        for path in ["/", "/Users/me", "/Users/me/", "/Users/me/Desktop", "/Users/me/Documents", "/Users/me/Downloads",
                     "/Users/me/Library", "/Applications", "/Library", "/System", "/System/Library", "/Users",
                     "/Volumes", "/Volumes/U盘", "/Volumes/U盘/"] {
            XCTAssertTrue(PathLogic.isProtected(path, home: home), path)
        }
    }

    func testThingsInsideAreFine() {
        for path in ["/Users/me/Downloads/a.zip", "/Users/me/Desktop/项目", "/Applications/Foo.app",
                     "/Volumes/U盘/照片", "/Users/me/Library/Caches/x", "/Users/me/DesktopOld", "/Users/other"] {
            XCTAssertFalse(PathLogic.isProtected(path, home: home), path)
        }
    }
}
