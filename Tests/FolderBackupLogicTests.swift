import XCTest

/// 备份到硬盘（Pro）：配对存取、认盘、比较、方向（只 Mac → 硬盘）、删除闸门、执行器。
final class FolderBackupLogicTests: XCTestCase {
    private var base: URL!
    private var mac: URL!
    private var drive: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("shiduo-backup-tests-\(UUID().uuidString)")
        mac = base.appendingPathComponent("Mac 文件夹", isDirectory: true)
        drive = base.appendingPathComponent("Drive", isDirectory: true).appendingPathComponent("备份", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - 工具

    private func write(_ text: String, _ rel: String, in root: URL, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func read(_ rel: String, in root: URL) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ rel: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    /// 一个文件夹里所有东西的「指纹」：相对路径 → 类型 + 大小 + 修改时间 + 内容。用来证明 Mac 那边一点没变。
    private func fingerprint(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return out }
        while let rel = e.nextObject() as? String {
            let attrs = e.fileAttributes ?? [:]
            let type = (attrs[.type] as? FileAttributeType)?.rawValue ?? "?"
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let content = type == FileAttributeType.typeRegular.rawValue ? (read(rel, in: root) ?? "") : ""
            out[rel] = "\(type)|\(size)|\(date)|\(content)"
        }
        return out
    }

    private func entry(_ path: String, _ kind: BackupEntry.Kind = .file, size: Int64 = 10, at seconds: TimeInterval = 1000) -> BackupEntry {
        BackupEntry(path: path, kind: kind, size: size, modified: Date(timeIntervalSince1970: seconds))
    }

    private func entries(_ list: [BackupEntry]) -> [String: BackupEntry] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0) })
    }

    private var roots: BackupRoots { BackupRoots(mac: mac.path, drive: drive.path)! }

    /// 扫两边 → 比较 → 执行。
    @discardableResult
    private func backup(includeDeletes: Bool = false, io: BackupIO = .basic, cancel: BackupCancelFlag = BackupCancelFlag()) -> (BackupPlan, BackupRunResult) {
        let macSnap = BackupScanner.scan(mac.path)
        let driveSnap = BackupScanner.scan(drive.path)
        let plan = FolderBackupLogic.plan(mac: macSnap.entries, drive: driveSnap.entries, leftoverTemps: driveSnap.leftoverTemps)
        let result = BackupExecutor.run(plan.steps(includeDeletes: includeDeletes), roots: roots, allowDeletes: includeDeletes,
                                        io: io, cancel: cancel) { _ in }
        return (plan, result)
    }

    /// 测试用的「废纸篓」：移到临时目录里（不碰真正的废纸篓）。
    private func fakeTrashIO(into trash: URL) -> BackupIO {
        BackupIO(copyItem: BackupIO.basic.copyItem, trashItem: { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }, isDriveAvailable: { true })
    }

    // MARK: - 配对存取

    func testPairsRoundTrip() {
        var pair = BackupPair(macPath: "/Users/a/设计稿", volumeUUID: "1234-ABCD", volumeName: "小金刚",
                              volumeCapacity: 1_000_000, driveRelativePath: "备份/设计稿",
                              created: Date(timeIntervalSince1970: 1_700_000_000))
        pair.lastBackup = Date(timeIntervalSince1970: 1_800_000_000)
        pair.lastPending = 3
        let decoded = BackupPairsCodec.decode(BackupPairsCodec.encode([pair]))
        XCTAssertEqual(decoded, [pair])
    }

    func testNewPairIsOffByDefault() {
        let pair = BackupPair(macPath: "/Users/a/x", volumeUUID: nil, volumeName: "U", volumeCapacity: 1, driveRelativePath: "")
        XCTAssertFalse(pair.enabled)
        XCTAssertFalse(pair.autoBackupOnMount)
        XCTAssertFalse(pair.mirrorDeletes)
    }

    func testMissingSwitchesDecodeAsOff() {
        let json = """
        {"version": 1, "pairs": [{"id": "\(UUID().uuidString)", "macPath": "/Users/a/x", "volumeName": "U", "driveRelativePath": "b"}]}
        """
        let pairs = BackupPairsCodec.decode(Data(json.utf8))
        XCTAssertEqual(pairs.count, 1)
        XCTAssertFalse(pairs[0].enabled)
        XCTAssertFalse(pairs[0].autoBackupOnMount)
        XCTAssertFalse(pairs[0].mirrorDeletes)
    }

    func testBadPairsAreDroppedOthersKept() {
        let good = UUID().uuidString
        let json = """
        {"version": 7, "pairs": [
          {"id": "\(good)", "macPath": "/Users/a/x", "volumeName": "U", "driveRelativePath": "/a//b/"},
          {"id": "\(UUID().uuidString)", "macPath": "/Users/a/y", "volumeName": "U", "driveRelativePath": "../escape"},
          {"id": "\(UUID().uuidString)", "macPath": "relative/path", "volumeName": "U", "driveRelativePath": ""},
          {"id": "\(UUID().uuidString)", "volumeName": "no mac path"},
          {"id": "\(good)", "macPath": "/Users/a/dup", "volumeName": "U", "driveRelativePath": ""}
        ]}
        """
        let pairs = BackupPairsCodec.decode(Data(json.utf8))
        XCTAssertEqual(pairs.map(\.macPath), ["/Users/a/x"])
        XCTAssertEqual(pairs.first?.driveRelativePath, "a/b")
        XCTAssertEqual(BackupPairsCodec.decode(Data("garbage".utf8)), [])
        XCTAssertEqual(BackupPairsCodec.decode(nil), [])
    }

    // MARK: - 认盘和路径

    func testMatchesByUUIDNotName() {
        let pair = BackupPair(macPath: "/a", volumeUUID: "AAAA-1111", volumeName: "Backup", volumeCapacity: 500, driveRelativePath: "")
        let renamed = BackupVolumeInfo(mountPath: "/Volumes/新名字", uuid: "aaaa-1111", name: "新名字", capacity: 500, isExternal: true)
        let impostor = BackupVolumeInfo(mountPath: "/Volumes/Backup", uuid: "BBBB-2222", name: "Backup", capacity: 500, isExternal: true)
        let noUUID = BackupVolumeInfo(mountPath: "/Volumes/Backup", uuid: nil, name: "Backup", capacity: 500, isExternal: true)
        XCTAssertTrue(FolderBackupLogic.matches(pair, volume: renamed))
        XCTAssertFalse(FolderBackupLogic.matches(pair, volume: impostor))
        XCTAssertFalse(FolderBackupLogic.matches(pair, volume: noUUID))
    }

    func testMatchesByNameAndCapacityWithoutUUID() {
        let pair = BackupPair(macPath: "/a", volumeUUID: nil, volumeName: "U盘", volumeCapacity: 32_000, driveRelativePath: "")
        XCTAssertTrue(FolderBackupLogic.matches(pair, volume: BackupVolumeInfo(mountPath: "/Volumes/U盘 1", uuid: nil, name: "U盘", capacity: 32_000, isExternal: true)))
        XCTAssertFalse(FolderBackupLogic.matches(pair, volume: BackupVolumeInfo(mountPath: "/Volumes/U盘", uuid: nil, name: "U盘", capacity: 64_000, isExternal: true)))
    }

    func testRelativePathAndDriveRoot() {
        XCTAssertEqual(FolderBackupLogic.relativePath(of: "/Volumes/小金刚/备份/设计稿/", inVolume: "/Volumes/小金刚"), "备份/设计稿")
        XCTAssertEqual(FolderBackupLogic.relativePath(of: "/Volumes/小金刚", inVolume: "/Volumes/小金刚"), "")
        XCTAssertNil(FolderBackupLogic.relativePath(of: "/Volumes/小金刚2/a", inVolume: "/Volumes/小金刚"))
        let pair = BackupPair(macPath: "/a", volumeUUID: "X", volumeName: "小金刚", volumeCapacity: 1, driveRelativePath: "备份/设计稿")
        // 硬盘这次挂在了别的位置。
        XCTAssertEqual(FolderBackupLogic.driveRoot(for: pair, volumeMount: "/Volumes/小金刚 1"), "/Volumes/小金刚 1/备份/设计稿")
        XCTAssertNil(FolderBackupLogic.sanitizedRelative("a/../../etc"))
        XCTAssertNil(FolderBackupLogic.sanitizedRelative("./a"))
        XCTAssertEqual(FolderBackupLogic.sanitizedRelative("//a///b/"), "a/b")
    }

    func testValidatePair() {
        let usb = BackupVolumeInfo(mountPath: "/Volumes/USB", uuid: "U-1", name: "USB", capacity: 9, isExternal: true)
        let internal = BackupVolumeInfo(mountPath: "/", uuid: "R-1", name: "Macintosh HD", capacity: 9, isExternal: false)
        XCTAssertNil(FolderBackupLogic.validate(macPath: "/Users/a/Docs", drivePath: "/Volumes/USB/Docs", driveVolume: usb))
        XCTAssertEqual(FolderBackupLogic.validate(macPath: "/Users/a/Docs", drivePath: "/Users/a/Backup", driveVolume: internal), .driveNotExternal)
        XCTAssertEqual(FolderBackupLogic.validate(macPath: "/Users/a/Docs", drivePath: "/Volumes/USB/x", driveVolume: nil), .driveNotExternal)
        XCTAssertEqual(FolderBackupLogic.validate(macPath: "/Volumes/USB/x", drivePath: "/Volumes/USB/x/", driveVolume: usb), .sameFolder)
        XCTAssertEqual(FolderBackupLogic.validate(macPath: "/Volumes/USB", drivePath: "/Volumes/USB/backup", driveVolume: usb), .driveInsideMac)
        XCTAssertEqual(FolderBackupLogic.validate(macPath: "/Volumes/USB/work/a", drivePath: "/Volumes/USB/work", driveVolume: usb), .macInsideDrive)
        let existing = BackupPair(macPath: "/Users/a/Docs", volumeUUID: "U-1", volumeName: "USB", volumeCapacity: 9, driveRelativePath: "Docs")
        XCTAssertEqual(FolderBackupLogic.validate(macPath: "/Users/a/Docs", drivePath: "/Volumes/USB/Docs", driveVolume: usb, existing: [existing]), .duplicate)
        // 名字只是前缀相同不算「在里面」。
        XCTAssertNil(FolderBackupLogic.validate(macPath: "/Volumes/USB/work", drivePath: "/Volumes/USB/work2", driveVolume: usb))
    }

    // MARK: - 比较

    func testPlanSortsNewChangedOnlyOnDrive() {
        let macSide = entries([
            entry("a.txt"), entry("改过.psd", size: 20, at: 2000), entry("没变.jpg", at: 1001.5),
            entry("新文件夹", .folder), entry("新文件夹/里面.txt"), entry("空文件夹", .folder),
        ])
        let driveSide = entries([
            entry("改过.psd", size: 10, at: 1000), entry("没变.jpg", at: 1000),
            entry("硬盘独有", .folder), entry("硬盘独有/1.txt"), entry("硬盘独有/2.txt"), entry("旧.doc"),
        ])
        let plan = FolderBackupLogic.plan(mac: macSide, drive: driveSide)
        XCTAssertEqual(plan.newFiles.map(\.path), ["a.txt", "新文件夹/里面.txt"])
        XCTAssertEqual(plan.changed.map(\.mac.path), ["改过.psd"])
        XCTAssertEqual(plan.foldersToCreate, ["新文件夹", "空文件夹"].sorted())
        XCTAssertEqual(Set(plan.onlyOnDrive.map(\.path)), ["硬盘独有", "旧.doc"])
        XCTAssertEqual(plan.onlyOnDriveFileCount, 3)
        XCTAssertEqual(plan.pendingCount, 3)
        XCTAssertEqual(plan.bytesToCopy, 10 + 10 + 20)
    }

    func testTwoSecondTolerance() {
        XCTAssertTrue(FolderBackupLogic.isSame(entry("a", at: 1000), entry("a", at: 1002)))
        XCTAssertFalse(FolderBackupLogic.isSame(entry("a", at: 1000), entry("a", at: 1003)))
        XCTAssertFalse(FolderBackupLogic.isSame(entry("a", size: 10), entry("a", size: 11)))
    }

    func testDriveNewerIsFlaggedButMacStillWins() {
        let plan = FolderBackupLogic.plan(mac: entries([entry("a", size: 5, at: 1000)]), drive: entries([entry("a", size: 6, at: 5000)]))
        XCTAssertEqual(plan.changed.count, 1)
        XCTAssertTrue(plan.changed[0].driveIsNewer)
        XCTAssertEqual(plan.steps(includeDeletes: false), [.copy("a", size: 5)])
    }

    func testFolderVersusFileConflictIsSkipped() {
        let macSide = entries([entry("x", .folder), entry("x/1.txt"), entry("y")])
        let driveSide = entries([entry("x"), entry("y", .folder), entry("y/old.txt")])
        let plan = FolderBackupLogic.plan(mac: macSide, drive: driveSide)
        XCTAssertEqual(plan.conflicts, ["x", "y"])
        XCTAssertTrue(plan.newFiles.isEmpty)
        XCTAssertTrue(plan.onlyOnDrive.isEmpty, "冲突下面的东西不能当成「只在硬盘上」（镜像时会被删掉）")
    }

    // MARK: - 方向：只 Mac → 硬盘

    func testOnlyOnDriveNeverBecomesACopy() {
        let plan = FolderBackupLogic.plan(mac: [:], drive: entries([entry("只在硬盘.mov", size: 999)]))
        XCTAssertEqual(plan.pendingCount, 0)
        XCTAssertEqual(plan.steps(includeDeletes: false), [])
        XCTAssertEqual(plan.steps(includeDeletes: true), [.trash("只在硬盘.mov")])
    }

    func testRootsDirectionIsFixed() throws {
        let r = try XCTUnwrap(BackupRoots(mac: "/Users/a/Docs", drive: "/Volumes/USB/Docs"))
        XCTAssertEqual(r.source("x/y.txt")?.path, "/Users/a/Docs/x/y.txt")
        XCTAssertEqual(r.target("x/y.txt")?.path, "/Volumes/USB/Docs/x/y.txt")
        XCTAssertTrue(r.isWritable(try XCTUnwrap(r.target("x/y.txt"))))
        XCTAssertFalse(r.isWritable(try XCTUnwrap(r.source("x/y.txt"))), "Mac 文件夹永远不能写")
        XCTAssertFalse(r.isWritable(URL(fileURLWithPath: "/Volumes/USB/Docs")), "不能动硬盘文件夹本身")
        XCTAssertFalse(r.isWritable(URL(fileURLWithPath: "/Volumes/USB/Other/a")))
        XCTAssertNil(r.target("../../../Users/a/Docs/x"), "相对路径跳不出去")
        XCTAssertNil(r.source(""))
        XCTAssertNil(BackupRoots(mac: "/Volumes/USB", drive: "/Volumes/USB/Docs"))
        XCTAssertNil(BackupRoots(mac: "/Volumes/USB/Docs/inner", drive: "/Volumes/USB/Docs"))
        XCTAssertNil(BackupRoots(mac: "/a", drive: "/a/"))
        XCTAssertNil(BackupRoots(mac: "relative", drive: "/Volumes/USB"))
    }

    func testBackupNeverTouchesMacEvenWithDriveOnlyFiles() throws {
        try write("新的", "new.txt", in: mac)
        try write("Mac 版本 2", "doc/改过.txt", in: mac, modified: Date(timeIntervalSince1970: 1_900_000_000))
        try write("硬盘旧版", "doc/改过.txt", in: drive, modified: Date(timeIntervalSince1970: 1_800_000_000))
        try write("只在硬盘", "只在硬盘.txt", in: drive)
        try write("只在硬盘 2", "硬盘文件夹/深/x.txt", in: drive)
        let before = fingerprint(mac)

        let (plan, result) = backup()
        XCTAssertEqual(plan.pendingCount, 2)
        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(read("new.txt", in: drive), "新的")
        XCTAssertEqual(read("doc/改过.txt", in: drive), "Mac 版本 2")
        // 默认不删硬盘上的任何东西。
        XCTAssertEqual(read("只在硬盘.txt", in: drive), "只在硬盘")
        XCTAssertEqual(read("硬盘文件夹/深/x.txt", in: drive), "只在硬盘 2")
        // Mac 这边一点没变，也没有被拷回任何东西。
        XCTAssertEqual(fingerprint(mac), before)
        XCTAssertFalse(exists("只在硬盘.txt", in: mac))
        XCTAssertFalse(exists("硬盘文件夹", in: mac))
    }

    func testModifiedDatesKeptSoSecondRunHasNothingToDo() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("hello", "a/b/c.txt", in: mac, modified: date)
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("空的"), withIntermediateDirectories: true)
        backup()
        let attrs = try FileManager.default.attributesOfItem(atPath: drive.appendingPathComponent("a/b/c.txt").path)
        let copied = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(copied.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(exists("空的", in: drive))
        let (again, _) = backup()
        XCTAssertEqual(again.pendingCount, 0)
        XCTAssertFalse(again.hasWork)
    }

    func testJunkIsSkipped() throws {
        try write("x", ".DS_Store", in: mac)
        try write("x", "._photo.jpg", in: mac)
        try write("x", "~$报价单.docx", in: mac)
        try write("ok", ".hidden-but-real", in: mac)
        try write("x", ".DS_Store", in: drive)
        let snap = BackupScanner.scan(mac.path)
        XCTAssertEqual(Set(snap.entries.keys), [".hidden-but-real"])
        let (plan, _) = backup()
        XCTAssertTrue(plan.onlyOnDrive.isEmpty, "硬盘上的 .DS_Store 不算「只在硬盘上」")
        XCTAssertFalse(exists("._photo.jpg", in: drive))
        XCTAssertTrue(exists(".hidden-but-real", in: drive))
    }

    // MARK: - 删除的闸门

    func testDeletionNeedsMirrorAndConfirmation() {
        var pair = BackupPair(macPath: "/a", volumeUUID: "X", volumeName: "U", volumeCapacity: 1, driveRelativePath: "")
        XCTAssertFalse(FolderBackupLogic.deletionAllowed(pair: pair, userConfirmed: true))
        XCTAssertFalse(FolderBackupLogic.deletionAllowed(pair: pair, userConfirmed: false))
        pair.mirrorDeletes = true
        XCTAssertFalse(FolderBackupLogic.deletionAllowed(pair: pair, userConfirmed: false))
        XCTAssertTrue(FolderBackupLogic.deletionAllowed(pair: pair, userConfirmed: true))
    }

    func testExecutorIgnoresTrashStepsWithoutPermission() throws {
        try write("留着", "old.txt", in: drive)
        let trash = base.appendingPathComponent("trash")
        let result = BackupExecutor.run([.trash("old.txt")], roots: roots, allowDeletes: false, io: fakeTrashIO(into: trash),
                                        cancel: BackupCancelFlag()) { _ in }
        XCTAssertEqual(result.trashed, 0)
        XCTAssertTrue(exists("old.txt", in: drive))
    }

    func testMirrorMovesDriveOnlyItemsToTrashAndLeavesMacAlone() throws {
        try write("keep", "keep.txt", in: mac)
        try write("keep", "keep.txt", in: drive)
        try write("gone", "deleted on mac.txt", in: drive)
        try write("gone", "old folder/a.txt", in: drive)
        let before = fingerprint(mac)
        let trash = base.appendingPathComponent("trash")
        let (plan, result) = backup(includeDeletes: true, io: fakeTrashIO(into: trash))
        XCTAssertEqual(plan.onlyOnDrive.count, 2)
        XCTAssertEqual(result.trashed, 2)
        XCTAssertFalse(exists("deleted on mac.txt", in: drive))
        XCTAssertFalse(exists("old folder", in: drive))
        XCTAssertTrue(exists("keep.txt", in: drive))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.count, 2, "进了废纸篓，没有直接删")
        XCTAssertEqual(fingerprint(mac), before)
    }

    func testTrashFailureKeepsTheFile() throws {
        try write("gone", "x.txt", in: drive)
        let io = BackupIO(copyItem: BackupIO.basic.copyItem, trashItem: { _ in throw CocoaError(.fileWriteNoPermission) },
                          isDriveAvailable: { true })
        let result = BackupExecutor.run([.trash("x.txt")], roots: roots, allowDeletes: true, io: io, cancel: BackupCancelFlag()) { _ in }
        XCTAssertEqual(result.trashFailed, ["x.txt"])
        XCTAssertTrue(exists("x.txt", in: drive), "移不进废纸篓就留着，不直接删")
    }

    // MARK: - 意外

    func testDriveUnpluggedMidCopy() throws {
        for i in 1...4 { try write("file \(i)", "f\(i).txt", in: mac) }
        try write("old", "f3.txt", in: drive, modified: Date(timeIntervalSince1970: 1_000_000))
        var calls = 0
        var plugged = true
        let io = BackupIO(copyItem: { from, to, _ in
            calls += 1
            if calls == 2 {
                plugged = false
                throw CocoaError(.fileWriteVolumeReadOnly)
            }
            try FileManager.default.copyItem(at: from, to: to)
        }, trashItem: { _ in }, isDriveAvailable: { plugged })
        let (_, result) = backup(io: io)
        XCTAssertTrue(result.driveDisconnected)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(read("f3.txt", in: drive), "old", "没拷完的不会替换掉旧版本")
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: drive.path)).filter(BackupJunk.isTempName)
        XCTAssertEqual(leftovers, [], "半截的临时文件清掉")
    }

    func testLeftoverTempFilesAreCleanedNextTime() throws {
        try write("half", BackupJunk.tempPrefix + "dead.tmp", in: drive)
        try write("x", "a.txt", in: mac)
        let driveSnap = BackupScanner.scan(drive.path)
        XCTAssertEqual(driveSnap.leftoverTemps, [BackupJunk.tempPrefix + "dead.tmp"])
        XCTAssertTrue(driveSnap.entries.isEmpty)
        backup()
        XCTAssertFalse(exists(BackupJunk.tempPrefix + "dead.tmp", in: drive))
        XCTAssertTrue(exists("a.txt", in: drive))
    }

    func testCancelledBeforeStart() throws {
        try write("x", "a.txt", in: mac)
        let cancel = BackupCancelFlag()
        cancel.cancel()
        let (_, result) = backup(cancel: cancel)
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.copied, 0)
        XCTAssertFalse(exists("a.txt", in: drive))
    }

    func testRefusesWhenMacFolderMissing() throws {
        try write("keep", "keep.txt", in: drive)
        let missingMac = base.appendingPathComponent("not-there")
        let r = try XCTUnwrap(BackupRoots(mac: missingMac.path, drive: drive.path))
        let result = BackupExecutor.run([.trash("keep.txt")], roots: r, allowDeletes: true,
                                        io: fakeTrashIO(into: base.appendingPathComponent("trash")), cancel: BackupCancelFlag()) { _ in }
        XCTAssertTrue(result.refused)
        XCTAssertTrue(exists("keep.txt", in: drive))
    }

    func testProgressCountsBytes() throws {
        try write("12345", "a.txt", in: mac)
        try write("1234567890", "b.txt", in: mac)
        let plan = FolderBackupLogic.plan(mac: BackupScanner.scan(mac.path).entries, drive: [:])
        var last = BackupProgress()
        let result = BackupExecutor.run(plan.steps(includeDeletes: false), roots: roots, allowDeletes: false, io: .basic,
                                        cancel: BackupCancelFlag()) { last = $0 }
        XCTAssertEqual(result.copiedBytes, 15)
        XCTAssertEqual(last.fileCount, 2)
        XCTAssertEqual(last.filesDone, 2)
        XCTAssertEqual(last.bytesTotal, 15)
        XCTAssertEqual(last.bytesDone, 15)
    }

    // MARK: - 空间和提示

    func testRequiredSpace() {
        var plan = BackupPlan()
        plan.newFiles = [entry("a", size: 100)]
        plan.changed = [BackupChange(mac: entry("b", size: 50), drive: entry("b", size: 30)),
                        BackupChange(mac: entry("c", size: 10), drive: entry("c", size: 40))]
        XCTAssertEqual(FolderBackupLogic.requiredBytes(plan), 100 + 20 + 50)
        XCTAssertTrue(FolderBackupLogic.hasEnoughSpace(required: 100, available: 200, margin: 50))
        XCTAssertFalse(FolderBackupLogic.hasEnoughSpace(required: 100, available: 149, margin: 50))
        XCTAssertTrue(FolderBackupLogic.hasEnoughSpace(required: 0, available: 0))
    }

    func testMountAction() {
        var pair = BackupPair(macPath: "/a", volumeUUID: "X", volumeName: "U", volumeCapacity: 1, driveRelativePath: "")
        XCTAssertEqual(FolderBackupLogic.mountAction(pair: pair, isPro: true, pendingCount: 3), .nothing, "开关默认关：插上也什么都不做")
        pair.enabled = true
        XCTAssertEqual(FolderBackupLogic.mountAction(pair: pair, isPro: false, pendingCount: 3), .nothing)
        XCTAssertEqual(FolderBackupLogic.mountAction(pair: pair, isPro: true, pendingCount: 0), .nothing)
        XCTAssertEqual(FolderBackupLogic.mountAction(pair: pair, isPro: true, pendingCount: 3), .prompt(3))
        pair.autoBackupOnMount = true
        XCTAssertEqual(FolderBackupLogic.mountAction(pair: pair, isPro: true, pendingCount: 3), .autoBackup(3))
        XCTAssertEqual(FolderBackupLogic.promptText(count: 3, driveName: "小金刚"), "有 3 个新文件/改动要备份到「小金刚」")
    }

    // MARK: - 右键菜单

    func testContextMenuItemAddedAfterMoveOutInSavedLayouts() {
        var old = MenuCatalog.defaultLayout(.file)
        old.entries.removeAll { $0.id == "backupToDrive" }
        let merged = old.merged(withDefault: MenuCatalog.defaultLayout(.file))
        let ids = merged.allItemIDs
        XCTAssertEqual(ids.firstIndex(of: "backupToDrive"), ids.firstIndex(of: "moveOut").map { $0 + 1 })
        XCTAssertEqual(MenuCatalog.title("backupToDrive"), "备份到硬盘…")
    }
}
