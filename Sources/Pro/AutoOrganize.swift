import OSLog
import AppKit
import SwiftUI

// MARK: - 规则

enum RuleAction: String, Codable, Hashable {
    case move
    case trash
}

/// 一条自动整理规则：监视一个文件夹（只看第一层），所有条件同时满足的文件执行动作。
struct OrganizeRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var enabled: Bool = true
    var watchFolder: String
    /// FileCategory 的 rawValue；nil 表示不限类型。
    var category: String?
    /// 小写、不带点的扩展名；空表示不限。
    var extensions: [String] = []
    var nameContains: String = ""
    /// SourceCatalog 里的来源 id，例如 "wechat"；nil 表示不限来源。
    var sourceID: String?
    /// 加入文件夹超过 N 天；nil 或 0 表示不限。
    var olderThanDays: Int?
    var action: RuleAction = .move
    /// 动作是移动时的目标文件夹。
    var destination: String?

    static var defaultWatchFolder: String { Folders.downloads }

    /// 至少有一个条件，避免一条空规则把整个文件夹都搬走。
    var hasCondition: Bool {
        category != nil || !extensions.isEmpty
            || !nameContains.trimmingCharacters(in: .whitespaces).isEmpty
            || sourceID != nil || (olderThanDays ?? 0) > 0
    }

    var isRunnable: Bool {
        guard hasCondition, !watchFolder.isEmpty else { return false }
        if action == .move {
            guard let destination, !destination.isEmpty else { return false }
        }
        return true
    }

    /// 条件部分（「整理下载」预览也用它）。
    var conditions: OrganizeConditions {
        OrganizeConditions(category: category, extensions: extensions, nameContains: nameContains,
                           sourceID: sourceID, olderThanDays: olderThanDays)
    }

    func matches(_ item: FileItem, now: Date) -> Bool {
        if item.isDirectory { return false }
        if OrganizeEngine.partialExtensions.contains(item.ext) { return false }
        // 刚下载完或还在写入的文件先放一放（后台自动整理等 2 分钟；用户在预览里确认的只等几秒）。
        if let modified = item.modified, now.timeIntervalSince(modified) < 120 { return false }
        return conditions.matches(OrganizeCandidate(item: item), now: now)
    }

    static func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return String(localized: "未选择") }
        return FileManager.default.displayName(atPath: path)
    }

    var summary: String {
        var parts: [String] = []
        if let c = category.flatMap(FileCategory.init(rawValue:)) { parts.append(c.title) }
        if !extensions.isEmpty { parts.append(extensions.map { "." + $0 }.joined(separator: " ")) }
        let needle = nameContains.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { parts.append(String(localized: "名称含「\(needle)」")) }
        if let source = sourceID.flatMap(SourceCatalog.source(id:)) { parts.append(String(localized: "来自 \(source.name)")) }
        if let days = olderThanDays, days > 0 { parts.append(String(localized: "超过 \(days) 天")) }
        let condition = parts.isEmpty ? String(localized: "（还没有条件）") : parts.joined(separator: " · ")
        let target = action == .trash ? String(localized: "移到废纸篓") : String(localized: "移到「\(Self.folderName(destination))」")
        return String(localized: "\(Self.folderName(watchFolder))：\(condition) → \(target)")
    }

    /// 第一次打开时给两条示例规则，默认关闭，用户打开开关才会生效。
    static var examples: [OrganizeRule] {
        let home = NSHomeDirectory() as NSString
        return [
            OrganizeRule(name: String(localized: "旧安装包移到废纸篓"), enabled: false, watchFolder: Folders.downloads,
                         extensions: ["dmg", "pkg"], olderThanDays: 14, action: .trash),
            OrganizeRule(name: String(localized: "下载的 PDF 归到文稿"), enabled: false, watchFolder: Folders.downloads,
                         extensions: ["pdf"], olderThanDays: 3, action: .move,
                         destination: home.appendingPathComponent(String(localized: "Documents/下载的 PDF"))),
        ]
    }
}

/// 一次整理动作的记录。
struct OrganizeLogEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var ruleName: String
    var fileName: String
    /// 原来的位置。
    var from: String
    /// 新位置（移到废纸篓时是废纸篓里的路径，拿不到时为 nil）。
    var to: String?
    var action: RuleAction
    var undone: Bool = false

    var canUndo: Bool { !undone && to != nil }
}

// MARK: - 执行（不在主线程）

enum OrganizeEngine {
    /// 还没下载完的文件。
    static let partialExtensions: Set<String> = DownloadsPlanLogic.partialExtensions

    /// 规则跑不了的原因（显示在规则下面）。
    enum Problem: String, Codable, Hashable {
        /// 监视的文件夹不在了（被改名、移走或删除）。
        case watchFolderMissing
        /// 要移去的文件夹不在了。不会自动重新建一个，免得在旧位置冒出一个同名文件夹。
        case destinationMissing
    }

    static func run(_ rules: [OrganizeRule], ignoring ignored: Set<String>, now: Date = Date())
        -> (entries: [OrganizeLogEntry], problems: [UUID: Problem]) {
        let fm = FileManager.default
        var entries: [OrganizeLogEntry] = []
        var problems: [UUID: Problem] = [:]
        var handled = Set<String>()
        for rule in rules where rule.enabled && rule.isRunnable {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rule.watchFolder, isDirectory: &isDir), isDir.boolValue else {
                problems[rule.id] = .watchFolderMissing
                continue
            }
            if rule.action == .move, let destination = rule.destination {
                var destIsDir: ObjCBool = false
                guard fm.fileExists(atPath: destination, isDirectory: &destIsDir), destIsDir.boolValue else {
                    problems[rule.id] = .destinationMissing
                    continue
                }
            }
            let folder = URL(fileURLWithPath: rule.watchFolder, isDirectory: true)
            guard let urls = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                let path = url.path
                if handled.contains(path) || ignored.contains(path) { continue }
                // 只在 iCloud 云端的占位文件不动。
                if url.pathExtension == "icloud" || !FileActions.isLocal(url) { continue }
                guard let item = FileItem(url: url), rule.matches(item, now: now) else { continue }
                if let entry = apply(rule, to: url, now: now) {
                    entries.append(entry)
                    handled.insert(path)
                }
            }
        }
        return (entries, problems)
    }

    static func apply(_ rule: OrganizeRule, to url: URL, now: Date) -> OrganizeLogEntry? {
        let fm = FileManager.default
        switch rule.action {
        case .move:
            guard let destination = rule.destination, !destination.isEmpty else { return nil }
            let folder = URL(fileURLWithPath: destination, isDirectory: true)
            let source = url.deletingLastPathComponent().standardizedFileURL.path
            if folder.standardizedFileURL.path == source { return nil }
            // 目标文件夹不在了就不动（run 里已经记成问题）；不自动重新建，免得在旧位置冒出一个同名文件夹。
            guard fm.fileExists(atPath: folder.path) else { return nil }
            do {
                let target = uniqueURL(for: url.lastPathComponent, in: folder)
                // moveItem 遇到同名文件会失败而不是覆盖；uniqueURL 已经避开了同名。
                try fm.moveItem(at: url, to: target)
                return OrganizeLogEntry(date: now, ruleName: rule.name, fileName: url.lastPathComponent,
                                        from: url.path, to: target.path, action: .move)
            } catch {
                AppLog.organize.error("Auto-organize move failed: \(AppLog.describe(error), privacy: .public)")
                return nil
            }
        case .trash:
            var resulting: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
                AppLog.organize.error("Auto-organize trash failed: \(AppLog.describe(error), privacy: .public)")
                return nil
            }
            return OrganizeLogEntry(date: now, ruleName: rule.name, fileName: url.lastPathComponent,
                                    from: url.path, to: resulting?.path, action: .trash)
        }
    }

    /// 文件夹里不重名的位置：「报告.pdf」已存在时用「报告 2.pdf」「报告 3.pdf」……
    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    /// 把文件放回原处。原处已有同名文件时加编号。返回放回后的路径。
    static func undo(_ entry: OrganizeLogEntry) -> String? {
        let fm = FileManager.default
        guard let to = entry.to, fm.fileExists(atPath: to) else { return nil }
        let original = URL(fileURLWithPath: entry.from)
        let folder = original.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = fm.fileExists(atPath: original.path)
            ? uniqueURL(for: original.lastPathComponent, in: folder)
            : original
        do {
            try fm.moveItem(at: URL(fileURLWithPath: to), to: target)
            return target.path
        } catch {
            return nil
        }
    }
}

// MARK: - 状态与定时

/// 自动整理：拾掇开着时每 10 分钟、以及启动时各跑一次（没有后台常驻进程）。
@MainActor
final class AutoOrganizer: ObservableObject {
    @Published var rules: [OrganizeRule] = [] {
        didSet {
            guard loaded else { return }
            saveRules()
            createDestinationsForNewlyEnabled(old: oldValue)
        }
    }
    /// 上一轮发现跑不了的规则（监视 / 目标文件夹不在了）。
    @Published private(set) var problems: [UUID: OrganizeEngine.Problem] = [:]
    @Published private(set) var log: [OrganizeLogEntry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?

    /// 撤销过的文件不再被规则自动处理。按加入的先后排，超过上限时去掉最旧的。
    private(set) var ignored: [String] = []
    private static let ignoredLimit = 500
    private var loaded = false
    private var timer: Task<Void, Never>?

    static let interval: UInt64 = 600 * 1_000_000_000

    private struct LogFile: Codable {
        var entries: [OrganizeLogEntry]
        var ignored: [String]
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Shiduo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var rulesURL: URL { Self.directory.appendingPathComponent("rules.json") }
    private var logURL: URL { Self.directory.appendingPathComponent("organize-log.json") }

    init() {
        if let data = try? Data(contentsOf: rulesURL),
           let decoded = try? JSONDecoder().decode([OrganizeRule].self, from: data) {
            rules = decoded
        } else {
            rules = OrganizeRule.examples
        }
        if let data = try? Data(contentsOf: logURL),
           let decoded = try? JSONDecoder().decode(LogFile.self, from: data) {
            log = decoded.entries
            ignored = decoded.ignored
        }
        loaded = true
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: rulesURL, options: .atomic)
        }
    }

    private func saveLog() {
        let file = LogFile(entries: log, ignored: ignored)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    /// 启动时调用：马上整理一次，之后每 10 分钟一次。
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runNow()
                try? await Task.sleep(nanoseconds: AutoOrganizer.interval)
            }
        }
    }

    /// only 不为空时只跑这一条规则（例如刚在清理页打开安装包开关）。
    func runNow(only ruleID: UUID? = nil) async {
        guard LicenseManager.shared.isPro, !isRunning else { return }
        let active = rules.filter { $0.enabled && $0.isRunnable && (ruleID == nil || $0.id == ruleID) }
        lastRun = Date()
        guard !active.isEmpty else { return }
        isRunning = true
        let skip = Set(ignored)
        let (entries, found) = await Task.detached(priority: .utility) {
            OrganizeEngine.run(active, ignoring: skip)
        }.value
        isRunning = false
        // 只更新这次跑过的规则的问题标记。
        var merged = problems.filter { id, _ in !active.contains { $0.id == id } }
        merged.merge(found) { _, new in new }
        if merged != problems { problems = merged }
        guard !entries.isEmpty else { return }
        log = Array((Array(entries.reversed()) + log).prefix(50))
        saveLog()
        // 规则移到废纸篓的文件也记进「清理记录」，30 天内可以放回原处。
        let trashed = entries.filter { $0.action == .trash }
        if !trashed.isEmpty {
            CleanupHistory.shared.recordTrash(trashed.map { entry in
                let size = entry.to.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.int64Value
                } ?? 0
                return (name: entry.fileName, original: entry.from, trashed: entry.to, size: size)
            }, date: trashed.first?.date ?? Date())
        }
        // 主窗口的列表、清理卡片、重复文件、暂存架里去掉这些文件；正在看来源或目标文件夹时悄悄刷新。
        LibraryStore.shared?.organizerMoved(entries)
    }

    func undo(_ entry: OrganizeLogEntry) -> Bool {
        guard entry.canUndo, let restored = OrganizeEngine.undo(entry) else { return false }
        addIgnored([restored])
        if let index = log.firstIndex(where: { $0.id == entry.id }) {
            log[index].undone = true
        }
        saveLog()
        // 清理记录里对应的那条（移到废纸篓的）也标成已恢复。
        if entry.action == .trash {
            CleanupHistory.shared.markRestored(original: entry.from, trashed: entry.to, at: restored)
        }
        LibraryStore.shared?.filesChanged()
        return true
    }

    /// 用户从「清理记录」里放回的文件：规则以后不再自动处理，免得下一轮又被移走。
    func ignore(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        addIgnored(paths)
        saveLog()
    }

    private func addIgnored(_ paths: [String]) {
        ignored = OrganizeIgnoreList.adding(paths, to: ignored, limit: Self.ignoredLimit)
    }

    /// 清理记录里恢复了自动整理移到废纸篓的文件：整理日志里那条标成已撤销，不再显示「撤销」按钮。
    func markRestored(_ records: [CleanupRecord]) {
        var changed = false
        for record in records where record.action == .trash {
            if let index = log.firstIndex(where: {
                !$0.undone && $0.action == .trash && $0.from == record.originalPath
            }) {
                log[index].undone = true
                changed = true
            }
        }
        if changed { saveLog() }
    }

    /// 文件夹在拾掇里改名 / 移动了（文件夹墙）：规则里的监视文件夹和目标文件夹跟着改。
    func retarget(from old: String, to new: String) {
        var updated = rules
        var changed = false
        for index in updated.indices {
            if let path = PathLogic.rewrite(updated[index].watchFolder, from: old, to: new) {
                updated[index].watchFolder = path
                changed = true
            }
            if let destination = updated[index].destination,
               let path = PathLogic.rewrite(destination, from: old, to: new) {
                updated[index].destination = path
                changed = true
            }
        }
        if changed {
            rules = updated
            problems = problems.filter { id, _ in !updated.contains { $0.id == id } }
        }
    }

    /// 用户刚打开开关（或新建、改了目标）的移动规则：目标文件夹还没有就在这时建好（这是用户自己的操作）。
    /// 之后每 10 分钟跑的时候不会再自动建。
    private func createDestinationsForNewlyEnabled(old: [OrganizeRule]) {
        let fm = FileManager.default
        for rule in rules where rule.enabled && rule.action == .move {
            guard let destination = rule.destination, !destination.isEmpty else { continue }
            let before = old.first { $0.id == rule.id }
            let justEnabled = before == nil || before?.enabled == false || before?.destination != destination
            guard justEnabled, !fm.fileExists(atPath: destination) else { continue }
            try? fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
            problems[rule.id] = nil
        }
    }

    func clearLog() {
        log = []
        saveLog()
    }

    func save(_ rule: OrganizeRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }

    func delete(_ rule: OrganizeRule) {
        rules.removeAll { $0.id == rule.id }
    }

    // MARK: 清理页的「自动清理用过的安装包」开关

    /// 开关新建的那条规则用固定的 id，方便以后找到它。
    static let installerRuleID = UUID(uuidString: "5A1D0D00-1A57-4A11-8E25-000000000001")!
    static let installerExtensions = ["dmg", "pkg", "mpkg", "xip"]
    static let installerDefaultDays = 14

    /// 只把“下载”里的安装包移到废纸篓、没有别的条件的规则（开关新建的，或者第一次打开时给的示例规则）。
    private static func isInstallerRule(_ rule: OrganizeRule) -> Bool {
        if rule.id == installerRuleID { return true }
        return rule.action == .trash && rule.watchFolder == Folders.downloads
            && !rule.extensions.isEmpty && Set(rule.extensions).isSubset(of: Set(installerExtensions))
            && rule.category == nil && rule.sourceID == nil
            && rule.nameContains.trimmingCharacters(in: .whitespaces).isEmpty
            // 没设天数的规则不认领：否则一打开开关，刚下载的安装包也会立刻进废纸篓。
            && (rule.olderThanDays ?? 0) > 0
    }

    var installerRule: OrganizeRule? {
        rules.first { $0.id == Self.installerRuleID } ?? rules.first(where: Self.isInstallerRule)
    }

    /// 开关现在是不是开着（默认关闭）。
    var autoCleansInstallers: Bool {
        guard let rule = installerRule else { return false }
        return rule.enabled && rule.isRunnable
    }

    /// 打开 / 关上开关：改的是自动整理里那条规则，在「自动整理」页里也看得到、改得了。
    /// 只移到废纸篓（记进清理记录，30 天内能放回），不会直接删除。
    func setAutoCleanInstallers(_ on: Bool) {
        var ruleID = Self.installerRuleID
        if var rule = installerRule {
            rule.enabled = on
            // 安装包开关一定带天数：没设（或在自动整理页改成了 0）就补回 14 天。
            if on, (rule.olderThanDays ?? 0) <= 0 { rule.olderThanDays = Self.installerDefaultDays }
            save(rule)
            ruleID = rule.id
        } else if on {
            rules.append(OrganizeRule(
                id: Self.installerRuleID, name: String(localized: "自动清理用过的安装包"), enabled: true,
                watchFolder: Folders.downloads, extensions: Self.installerExtensions,
                olderThanDays: Self.installerDefaultDays, action: .trash
            ))
        }
        // 只跑这一条，不顺带触发其他自动整理规则。
        if on { Task { await runNow(only: ruleID) } }
    }
}

// MARK: - 界面

struct AutoOrganizeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var organizer: AutoOrganizer
    @State private var editing: OrganizeRule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                // 现成的一条：自动清理用过的安装包（以前在清理页上，现在和其他规则放在一起）。
                AutoCleanInstallersRow()
                if organizer.rules.isEmpty {
                    Text("还没有规则。点「新建规则」，比如把下载文件夹里的安装包自动移到废纸篓。")
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                }
                ForEach($organizer.rules) { $rule in
                    RuleRow(rule: $rule, problem: organizer.problems[rule.id],
                            onEdit: { editing = rule }, onDelete: { organizer.delete(rule) })
                }
                logSection
                Label("只移动、不覆盖：同名文件会自动加编号；只在 iCloud 云端的文件会跳过。移到废纸篓的随时可以放回。", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("自动整理")
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { organizer.save($0) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("自动整理")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    ProBadge()
                }
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 先预览、确认后才移动的手动整理（可以一键撤销）。
            OrganizeDownloadsButton()
            Button {
                Task { await organizer.runNow() }
            } label: {
                HStack(spacing: 6) {
                    if organizer.isRunning { ProgressView().controlSize(.small) }
                    Label("立即整理", systemImage: "play.fill")
                }
                .glassCapsule()
            }
            .buttonStyle(.plain)
            .disabled(organizer.isRunning)
            Button {
                editing = OrganizeRule(name: String(localized: "新规则"), watchFolder: OrganizeRule.defaultWatchFolder)
            } label: {
                Label("新建规则", systemImage: "plus")
                    .glassCapsule(tint: .accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitle: String {
        var text = String(localized: "拾掇开着时，每 10 分钟按规则整理一次")
        if let last = organizer.lastRun {
            text += String(localized: " · 上次 \(last.formatted(date: .omitted, time: .shortened))")
        }
        return text
    }

    @ViewBuilder
    private var logSection: some View {
        if !organizer.log.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近的整理记录")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("清空记录") { organizer.clearLog() }
                        .buttonStyle(.borderless)
                }
                VStack(spacing: 0) {
                    ForEach(organizer.log) { entry in
                        LogRow(entry: entry) {
                            if !organizer.undo(entry) {
                                store.showToast(String(localized: "无法撤销：文件已经不在原来移去的位置"))
                            }
                        }
                        if entry.id != organizer.log.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
                .padding(.vertical, 4)
                .glassCard(radius: 16)
            }
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: OrganizeRule
    var problem: OrganizeEngine.Problem?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            TintedIcon(symbol: rule.action == .trash ? "trash" : "folder.badge.gearshape",
                       tint: rule.action == .trash ? .orange : .purple, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .fontWeight(.semibold)
                Text(rule.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !rule.isRunnable {
                    Text(rule.hasCondition ? String(localized: "请选择目标文件夹") : String(localized: "至少设置一个条件才会生效"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if rule.enabled, let problem {
                    Text(problem == .destinationMissing
                         ? String(localized: "目标文件夹不见了（被改名、移走或删除），请编辑规则重新选择")
                         : String(localized: "监视的文件夹不见了（被改名、移走或删除），请编辑规则重新选择"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("编辑", action: onEdit)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除规则")
            Toggle("启用", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(16)
        .glassCard(radius: 16)
    }
}

private struct LogRow: View {
    let entry: OrganizeLogEntry
    let onUndo: () -> Void

    private var target: String {
        if entry.action == .trash { return String(localized: "废纸篓") }
        guard let to = entry.to else { return "--" }
        return FileManager.default.displayName(atPath: (to as NSString).deletingLastPathComponent)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.action == .trash ? "trash" : "arrow.right.doc.on.clipboard")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.fileName) → \(target)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.ruleName) · \(entry.date.shortText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.undone {
                Text("已撤销")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.canUndo {
                Button("撤销", action: onUndo)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// 新建 / 编辑规则。
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OrganizeRule
    @State private var extensionsText: String
    let onSave: (OrganizeRule) -> Void

    init(rule: OrganizeRule, onSave: @escaping (OrganizeRule) -> Void) {
        _draft = State(initialValue: rule)
        _extensionsText = State(initialValue: rule.extensions.joined(separator: ", "))
        self.onSave = onSave
    }

    private var result: OrganizeRule {
        var rule = draft
        rule.name = rule.name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "未命名规则") : rule.name
        rule.extensions = Self.parseExtensions(extensionsText)
        rule.nameContains = rule.nameContains.trimmingCharacters(in: .whitespaces)
        if rule.action == .trash { rule.destination = nil }
        return rule
    }

    static func parseExtensions(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;； ")
        var seen = Set<String>()
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var days: Binding<Int> {
        Binding(
            get: { draft.olderThanDays ?? 0 },
            set: { draft.olderThanDays = $0 == 0 ? nil : $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $draft.name)
                    LabeledContent("监视文件夹") {
                        HStack {
                            Text(OrganizeRule.folderName(draft.watchFolder))
                                .help(draft.watchFolder)
                            Button("选择…") {
                                if let path = Self.chooseFolder(prompt: String(localized: "监视")) { draft.watchFolder = path }
                            }
                        }
                    }
                }

                Section {
                    Picker("文件类型", selection: $draft.category) {
                        Text("不限").tag(String?.none)
                        ForEach(FileCategory.allCases.filter { $0 != .recents }) { category in
                            Text(category.title).tag(Optional(category.rawValue))
                        }
                    }
                    TextField("扩展名", text: $extensionsText, prompt: Text("例如 dmg, pkg"))
                    TextField("文件名包含", text: $draft.nameContains, prompt: Text("例如 发票"))
                    Picker("下载来源", selection: $draft.sourceID) {
                        Text("不限").tag(String?.none)
                        ForEach(SourceCatalog.known) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }
                    Stepper(value: days, in: 0...365) {
                        Text(days.wrappedValue == 0 ? String(localized: "不限时间") : String(localized: "放进文件夹超过 \(days.wrappedValue) 天"))
                    }
                } header: {
                    Text("条件（全部满足才执行）")
                }

                Section("动作") {
                    Picker("动作", selection: $draft.action) {
                        Text("移到文件夹").tag(RuleAction.move)
                        Text("移到废纸篓").tag(RuleAction.trash)
                    }
                    .pickerStyle(.segmented)
                    if draft.action == .move {
                        LabeledContent("目标文件夹") {
                            HStack {
                                Text(OrganizeRule.folderName(draft.destination))
                                    .help(draft.destination ?? "")
                                Button("选择…") {
                                    if let path = Self.chooseFolder(prompt: String(localized: "移到这里")) { draft.destination = path }
                                }
                            }
                        }
                    }
                }

                if !result.isRunnable {
                    Text(result.hasCondition ? String(localized: "请选择目标文件夹。") : String(localized: "至少设置一个条件，避免把整个文件夹都搬走。"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!result.isRunnable)
            }
            .padding(16)
        }
        .frame(width: 500, height: 560)
    }

    static func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
