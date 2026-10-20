import XCTest

final class MoleBridgeTests: XCTestCase {
    func testParsesVersionLine() {
        let out = "\nMole version 1.61.0\nmacOS: 15.3.1\nArchitecture: arm64\nKernel: 24.3.0\nSIP: Enabled\nInstall: Homebrew\n"
        XCTAssertEqual(MoleLogic.parseVersion(out), "1.61.0")
        XCTAssertTrue(MoleLogic.reportsHomebrew(out))
    }

    func testParsesVersionWithColorsAndFallback() {
        XCTAssertEqual(MoleLogic.parseVersion("\u{1B}[1;32mMole version 1.51.0\u{1B}[0m"), "1.51.0")
        XCTAssertEqual(MoleLogic.parseVersion("macOS: 15.3\nV1.2.3\n"), "1.2.3")
        XCTAssertNil(MoleLogic.parseVersion("macOS: 15.3\nKernel: 24.3.0\n"))
        XCTAssertNil(MoleLogic.parseVersion(""))
        XCTAssertFalse(MoleLogic.reportsHomebrew("Mole version 1.0.0\nInstall: Manual\n"))
    }

    func testCompareVersions() {
        XCTAssertTrue(MoleLogic.isNewer("1.52.0", than: "1.51.0"))
        XCTAssertTrue(MoleLogic.isNewer("V1.10.0", than: "1.9.9"))
        XCTAssertTrue(MoleLogic.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(MoleLogic.isNewer("1.61", than: "1.61.0"))
        XCTAssertFalse(MoleLogic.isNewer("1.61.0", than: "1.61.0"))
        XCTAssertFalse(MoleLogic.isNewer("1.60.9", than: "1.61.0"))
        XCTAssertFalse(MoleLogic.isNewer("garbage", than: "1.0.0"))
        XCTAssertEqual(MoleLogic.compareVersions("1.61.0-beta", "1.61.0"), .orderedSame)
    }

    func testNormalizeTagAndLatestRelease() {
        XCTAssertEqual(MoleLogic.normalizeTag("V1.61.0"), "1.61.0")
        XCTAssertEqual(MoleLogic.normalizeTag("v0.1"), "0.1")
        let json = #"{"tag_name":"V1.61.0","name":"V1.61.0 Keeper"}"#.data(using: .utf8)!
        XCTAssertEqual(MoleLogic.parseLatestRelease(json), "1.61.0")
        XCTAssertNil(MoleLogic.parseLatestRelease(Data("{}".utf8)))
    }

    func testHomebrewPathAndCandidates() {
        XCTAssertTrue(MoleLogic.isHomebrewPath("/opt/homebrew/Cellar/mole/1.61.0/bin/mo"))
        XCTAssertTrue(MoleLogic.isHomebrewPath("/usr/local/Cellar/mole/1.61.0/libexec/mole"))
        XCTAssertFalse(MoleLogic.isHomebrewPath("/usr/local/bin/mo"))
        XCTAssertEqual(MoleLogic.candidatePaths(home: "/Users/a"),
                       ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", "/Users/a/.local/bin/mo"])
    }

    func testScripts() {
        let text = MoleLogic.ScriptText(header: "It's Mole", confirmClean: "Enter?", pressAnyKey: "Done")
        let clean = MoleLogic.script(for: .clean, mo: "/opt/homebrew/bin/mo", text: text)
        XCTAssertTrue(clean.hasPrefix("#!/bin/bash\n"))
        let dry = clean.range(of: "'/opt/homebrew/bin/mo' clean --dry-run")
        let real = clean.range(of: "'/opt/homebrew/bin/mo' clean\n")
        let confirm = clean.range(of: "read -r -p 'Enter?'")
        XCTAssertNotNil(dry); XCTAssertNotNil(real); XCTAssertNotNil(confirm)
        XCTAssertTrue(dry!.lowerBound < confirm!.lowerBound && confirm!.lowerBound < real!.lowerBound)
        XCTAssertTrue(clean.contains("echo 'It'\\''s Mole'"))

        XCTAssertEqual(MoleLogic.commands(for: .purge, mo: "/x/mo"), ["'/x/mo' purge"])
        // 「卸载 App」交给拾掇自己的卸载器，不再调用 mo uninstall。
        let all: [MoleLogic.TerminalAction] = [.clean, .purge, .analyze, .install(brew: nil), .update(viaHomebrew: false, brew: nil)]
        XCTAssertFalse(all.flatMap { MoleLogic.commands(for: $0, mo: "/x/mo") }.contains { $0.contains("uninstall") })
        XCTAssertEqual(MoleLogic.commands(for: .install(brew: "/opt/homebrew/bin/brew"), mo: "mo"),
                       ["'/opt/homebrew/bin/brew' install mole"])
        XCTAssertEqual(MoleLogic.commands(for: .install(brew: nil), mo: "mo"), [MoleLogic.scriptInstall])
        XCTAssertEqual(MoleLogic.commands(for: .update(viaHomebrew: true, brew: "/usr/local/bin/brew"), mo: "/x/mo"),
                       ["'/usr/local/bin/brew' upgrade mole"])
        XCTAssertEqual(MoleLogic.commands(for: .update(viaHomebrew: false, brew: "/usr/local/bin/brew"), mo: "/x/mo"),
                       ["'/x/mo' update"])
        XCTAssertEqual(MoleLogic.commands(for: .update(viaHomebrew: true, brew: nil), mo: "/x/mo"), ["'/x/mo' update"])
    }

    func testParseAnalyzeJSON() {
        let json = """
        Scanning…
        {"path":"/Users/a","overview":false,"scan_status":"partial",
         "entries":[{"name":"Small","path":"/Users/a/Small","size":10,"is_dir":true},
                    {"name":"Library","path":"/Users/a/Library","size":80939438080,"is_dir":true,"scan_status":"partial"},
                    {"name":"broken"}],
         "large_files":[{"name":"backup.zip","path":"/Users/a/backup.zip","size":8796093022}],
         "total_size":168393441280,"total_files":42187}
        """
        let r = MoleLogic.parseAnalyze(Data(json.utf8))
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.path, "/Users/a")
        XCTAssertEqual(r?.entries.map(\.name), ["Library", "Small"])
        XCTAssertEqual(r?.entries.first?.partial, true)
        XCTAssertEqual(r?.largeFiles.first?.isDirectory, false)
        XCTAssertEqual(r?.largeFiles.first?.size, 8_796_093_022)
        XCTAssertEqual(r?.totalSize, 168_393_441_280)
        XCTAssertEqual(r?.partial, true)
        XCTAssertNil(MoleLogic.parseAnalyze(Data("not json".utf8)))
        XCTAssertNil(MoleLogic.parseAnalyze(Data(#"{"foo":1}"#.utf8)))
    }
}
