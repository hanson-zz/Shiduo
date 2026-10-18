import XCTest

final class DownloadsPlanTests: XCTestCase {
    private let root = "/Users/me/Downloads"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, _ category: FileCategory? = nil, ageSeconds: TimeInterval = 3_600,
                      addedDaysAgo: Double = 1, dir: Bool = false, source: String? = nil) -> OrganizeCandidate {
        OrganizeCandidate(path: root + "/" + name, name: name, isDirectory: dir, size: 10, category: category,
                          sourceID: source, added: now.addingTimeInterval(-addedDaysAgo * 86_400),
                          created: nil, modified: now.addingTimeInterval(-ageSeconds))
    }

    private func names(_ plan: DownloadsPlanLogic.Plan) -> [String: String] {
        var map: [String: String] = [:]
        for item in plan.items {
            switch item.target {
            case .trash: map[item.candidate.name] = "TRASH"
            case .folder: map[item.candidate.name] = item.targetPath
            }
        }
        return map
    }

    func testSkipsInProgressDownloadsAndFolders() {
        let list = [
            file("a.crdownload"), file("b.download"), file("c.part"), file("d.partial"), file("e.opdownload"),
            file("fresh.pdf", .documents, ageSeconds: 2),
            file("Folder", dir: true),
            file("ok.pdf", .documents),
        ]
        let plan = DownloadsPlanLogic.plan(list, in: root, rules: [], now: now) { _ in false }
        XCTAssertEqual(plan.items.map(\.candidate.name), ["ok.pdf"])
        XCTAssertEqual(plan.skipped.count, 7)
        XCTAssertEqual(plan.skipped[list[0]], .downloading)
        XCTAssertEqual(plan.skipped[list[5]], .justModified)
        XCTAssertEqual(plan.skipped[list[6]], .folder)
        // 5 秒前改动的已经可以整理
        let settled = file("settled.pdf", .documents, ageSeconds: 6)
        XCTAssertNil(DownloadsPlanLogic.skipReason(settled, now: now))
    }

    func testTypeGroupingIntoSubfolders() {
        let list = [file("p.png", .images), file("m.mov", .videos), file("x.unknownext")]
        let plan = DownloadsPlanLogic.plan(list, in: root, rules: [], now: now,
                                           folderName: { $0?.rawValue ?? "other" }) { _ in false }
        let map = names(plan)
        XCTAssertEqual(map["p.png"], root + "/images/p.png")
        XCTAssertEqual(map["m.mov"], root + "/videos/m.mov")
        XCTAssertEqual(map["x.unknownext"], root + "/other/x.unknownext")
        XCTAssertTrue(plan.items.allSatisfy(\.createsFolder))
        XCTAssertTrue(plan.items.allSatisfy(\.checked))
    }

    func testRulesWinInOrderAndMissingDestinationFallsThrough() {
        let existing: Set<String> = ["/Users/me/Documents/PDF"]
        let missingRule = DownloadsPlanLogic.PlanRule(
            id: UUID(), name: "gone", watchFolder: root,
            conditions: OrganizeConditions(extensions: ["pdf"]), trash: false, destination: "/Volumes/Gone")
        let pdfRule = DownloadsPlanLogic.PlanRule(
            id: UUID(), name: "PDF", watchFolder: root + "/",
            conditions: OrganizeConditions(extensions: ["pdf"]), trash: false, destination: "/Users/me/Documents/PDF")
        let dmgRule = DownloadsPlanLogic.PlanRule(
            id: UUID(), name: "dmg", watchFolder: root,
            conditions: OrganizeConditions(extensions: ["dmg"], olderThanDays: 14), trash: true, destination: nil)
        let otherFolderRule = DownloadsPlanLogic.PlanRule(
            id: UUID(), name: "desktop", watchFolder: "/Users/me/Desktop",
            conditions: OrganizeConditions(extensions: ["png"]), trash: true, destination: nil)
        let list = [file("r.pdf", .documents), file("old.dmg", .archives, addedDaysAgo: 30),
                    file("new.dmg", .archives, addedDaysAgo: 1), file("s.png", .images)]
        let plan = DownloadsPlanLogic.plan(list, in: root, rules: [missingRule, pdfRule, dmgRule, otherFolderRule],
                                           now: now, folderName: { $0?.rawValue ?? "other" }) { existing.contains($0) }
        let map = names(plan)
        XCTAssertEqual(map["r.pdf"], "/Users/me/Documents/PDF/r.pdf")
        XCTAssertEqual(plan.items.first { $0.candidate.name == "r.pdf" }?.ruleName, "PDF")
        XCTAssertEqual(map["old.dmg"], "TRASH")
        XCTAssertEqual(map["new.dmg"], root + "/archives/new.dmg")
        XCTAssertEqual(map["s.png"], root + "/images/s.png")
        XCTAssertFalse(plan.items.first { $0.candidate.name == "r.pdf" }!.createsFolder)
    }

    func testNeverOverwritesExistingOrPlannedNames() {
        let existing: Set<String> = [root + "/documents", root + "/documents/a.pdf"]
        let other = OrganizeCandidate(path: "/elsewhere/a.pdf", name: "a.pdf", category: .documents,
                                      modified: now.addingTimeInterval(-3_600))
        // 两个都叫 a.pdf（一个在监视文件夹里、一个作为同名测试）：第二个要换编号
        var second = file("A.pdf", .documents)
        second.path = root + "/A.pdf"
        let plan = DownloadsPlanLogic.plan([file("a.pdf", .documents), second], in: root, rules: [], now: now,
                                           folderName: { $0?.rawValue ?? "other" }) { existing.contains($0) }
        let targets = Set(plan.items.compactMap(\.targetPath))
        XCTAssertEqual(targets.count, 2)
        XCTAssertFalse(targets.contains(root + "/documents/a.pdf"))
        XCTAssertTrue(targets.contains(root + "/documents/a 2.pdf") || targets.contains(root + "/documents/A 2.pdf"))
        XCTAssertFalse(plan.items.contains(where: \.createsFolder))
        _ = other
    }

    func testIgnoredFilesListedButUnchecked() {
        let list = [file("a.pdf", .documents), file("b.pdf", .documents)]
        let plan = DownloadsPlanLogic.plan(list, in: root, rules: [], ignored: [root + "/b.pdf"], now: now) { _ in false }
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertTrue(plan.items.first { $0.candidate.name == "a.pdf" }!.checked)
        let b = plan.items.first { $0.candidate.name == "b.pdf" }!
        XCTAssertFalse(b.checked)
        XCTAssertTrue(b.previouslyUndone)
    }

    func testGroupByTargetPutsTrashLast() {
        let rule = DownloadsPlanLogic.PlanRule(id: UUID(), name: "t", watchFolder: root,
                                               conditions: OrganizeConditions(extensions: ["dmg"]), trash: true, destination: nil)
        let plan = DownloadsPlanLogic.plan([file("a.dmg", .archives), file("p.png", .images), file("d.pdf", .documents)],
                                           in: root, rules: [rule], now: now,
                                           folderName: { $0?.rawValue ?? "other" }) { _ in false }
        let groups = DownloadsPlanLogic.groupByTarget(plan.items)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.last?.target, .trash)
        XCTAssertEqual(groups.first?.target, .folder(root + "/documents"))
    }

    func testDisplayGroupsByTypeAndDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let list = [
            file("p.png", .images, addedDaysAgo: 0),
            file("q.jpg", .images, addedDaysAgo: 3),
            file("d.pdf", .documents, addedDaysAgo: 20),
            file("z.zip", .archives, addedDaysAgo: 100),
            file("Sub", dir: true, addedDaysAgo: 1.5),
            file("x.crdownload", addedDaysAgo: 0),
        ]
        let byType = DownloadsPlanLogic.group(list, by: .type, now: now, calendar: cal)
        XCTAssertEqual(byType.map(\.key), ["images", "documents", "archives", "folder"])
        XCTAssertEqual(byType.first?.items.map(\.name), ["p.png", "q.jpg"])
        XCTAssertFalse(byType.flatMap(\.items).contains { $0.name == "x.crdownload" })

        let byDate = DownloadsPlanLogic.group(list, by: .dateAdded, now: now, calendar: cal)
        let keys = byDate.map(\.key)
        XCTAssertEqual(keys.first, "today")
        XCTAssertTrue(keys.contains("thisWeek"))
        XCTAssertTrue(keys.contains("thisMonth"))
        XCTAssertEqual(keys.last, "older")
    }

    func testDateBuckets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: now)
        XCTAssertEqual(DownloadsPlanLogic.dateBucket(today.addingTimeInterval(10), now: now, calendar: cal), .today)
        XCTAssertEqual(DownloadsPlanLogic.dateBucket(today.addingTimeInterval(-10), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(DownloadsPlanLogic.dateBucket(today.addingTimeInterval(-5 * 86_400), now: now, calendar: cal), .thisWeek)
        XCTAssertEqual(DownloadsPlanLogic.dateBucket(today.addingTimeInterval(-20 * 86_400), now: now, calendar: cal), .thisMonth)
        XCTAssertEqual(DownloadsPlanLogic.dateBucket(today.addingTimeInterval(-60 * 86_400), now: now, calendar: cal), .older)
        XCTAssertEqual(DownloadsPlanLogic.dateBucket(nil, now: now, calendar: cal), .unknown)
    }

    func testConditionsMatchLikeRules() {
        let c = file("发票-2026.PDF", .documents, addedDaysAgo: 5, source: "wechat")
        XCTAssertTrue(OrganizeConditions(extensions: ["pdf"]).matches(c, now: now))
        XCTAssertTrue(OrganizeConditions(nameContains: "发票").matches(c, now: now))
        XCTAssertFalse(OrganizeConditions(category: FileCategory.images.rawValue).matches(c, now: now))
        XCTAssertTrue(OrganizeConditions(sourceID: "wechat", olderThanDays: 3).matches(c, now: now))
        XCTAssertFalse(OrganizeConditions(olderThanDays: 7).matches(c, now: now))
        XCTAssertTrue(OrganizeConditions().isEmpty)
    }
}
