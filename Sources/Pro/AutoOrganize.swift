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

    func matches(_ item: FileItem, now: Date) -> Bool {
        if item.isDirectory { return false }
        if OrganizeEngine.partialExtensions.contains(item.ext) { return false }
        // 刚下载完或还在写入的文件先放一放。
        if let modified = item.modified, now.timeIntervalSince(modified) < 120 { return false }
        if let raw = category {
            guard let wanted = FileCategory(rawValue: raw), item.category == wanted else { return false }
        }
        if !extensions.isEmpty, !extensions.contains(item.ext) { return false }
        let needle = nameContains.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, !item.name.localizedCaseInsensitiveContains(needle) { return false }
        if let sourceID {
            guard item.downloadSource?.id == sourceID else { return false }
        }
        if let days = olderThanDays, days > 0 {
            let date = item.added ?? item.created ?? item.modified ?? now
            if now.timeIntervalSince(date) < TimeInterval(days) * 86_400 { return false }
        }
        return true
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
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    static func run(_ rules: [OrganizeRule], ignoring ignored: Set<String>, now: Date = Date()) -> [OrganizeLogEntry] {
        let fm = FileManager.default
        var entries: [OrganizeLogEntry] = []
        var handled = Set<String>()
        for rule in rules where rule.enabled && rule.isRunnable {
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
        return entries
    }

    static func apply(_ rule: OrganizeRule, to url: URL, now: Date) -> OrganizeLogEntry? {
        let fm = FileManager.default
        switch rule.action {
        case .move:
            guard let destination = rule.destination, !destination.isEmpty else { return nil }
            let folder = URL(fileURLWithPath: destination, isDirectory: true)
            let source = url.deletingLastPathComponent().standardizedFileURL.path
            if folder.standardizedFileURL.path == source { return nil }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = uniqueURL(for: url.lastPathComponent, in: folder)
                // moveItem 遇到同名文件会失败而不是覆盖；uniqueURL 已经避开了同名。
                try fm.moveItem(at: url, to: target)
                return OrganizeLogEntry(date: now, ruleName: rule.name, fileName: url.lastPathComponent,
                                        from: url.path, to: target.path, action: .move)
            } catch {
                return nil
            }
        case .trash:
            var resulting: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
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
        didSet { if loaded { saveRules() } }
    }
    @Published private(set) var log: [OrganizeLogEntry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?

    /// 撤销过的文件不再被规则自动处理。
    private var ignored: Set<String> = []
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
            ignored = Set(decoded.ignored)
        }
        loaded = true
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: rulesURL, options: .atomic)
        }
    }

    private func saveLog() {
        let file = LogFile(entries: log, ignored: Array(ignored.prefix(500)))
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

    func runNow() async {
        guard LicenseManager.shared.isPro, !isRunning else { return }
        let active = rules.filter { $0.enabled && $0.isRunnable }
        lastRun = Date()
        guard !active.isEmpty else { return }
        isRunning = true
        let skip = ignored
        let entries = await Task.detached(priority: .utility) { () -> [OrganizeLogEntry] in
            OrganizeEngine.run(active, ignoring: skip)
        }.value
        isRunning = false
        guard !entries.isEmpty else { return }
        log = Array((Array(entries.reversed()) + log).prefix(50))
        saveLog()
    }

    func undo(_ entry: OrganizeLogEntry) -> Bool {
        guard entry.canUndo, let restored = OrganizeEngine.undo(entry) else { return false }
        ignored.insert(restored)
        if let index = log.firstIndex(where: { $0.id == entry.id }) {
            log[index].undone = true
        }
        saveLog()
        return true
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
                if organizer.rules.isEmpty {
                    Text("还没有规则。点「新建规则」，比如把下载文件夹里的安装包自动移到废纸篓。")
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                }
                ForEach($organizer.rules) { $rule in
                    RuleRow(rule: $rule, onEdit: { editing = rule }, onDelete: { organizer.delete(rule) })
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
