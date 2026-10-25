import AppKit
import OSLog
import SwiftUI

// 「整理下载」：先预览每个文件要去哪儿，用户勾选、确认后才移动；一键「撤销全部」放回原处。
// 也可以只按类型 / 添加日期分组看看，不移动任何文件。纯规划逻辑在 DownloadsPlanLogic.swift。

extension OrganizeCandidate {
    init(item: FileItem) {
        self.init(path: item.path, name: item.name, isDirectory: item.isDirectory, size: item.size,
                  category: item.category, sourceID: item.downloadSource?.id,
                  added: item.added, created: item.created, modified: item.modified)
    }
}

extension OrganizeRule {
    /// 预览用：只有已启用、能跑的规则。
    var planRule: DownloadsPlanLogic.PlanRule? {
        guard enabled, isRunnable else { return nil }
        return DownloadsPlanLogic.PlanRule(id: id, name: name, watchFolder: watchFolder, conditions: conditions,
                                           trash: action == .trash, destination: destination)
    }
}

/// 执行结果（后台线程算出来，回主线程记录）。
struct DownloadsOrganizeOutcome {
    var moved: [(from: String, to: String, size: Int64)] = []
    var trashed: [(from: String, to: String?, size: Int64)] = []
    var createdFolders: [String] = []
    var failed: [String] = []
    /// 确认时文件已经不在了，或变成了正在下载。
    var gone: [String] = []

    var count: Int { moved.count + trashed.count }
}

enum DownloadsOrganizeEngine {
    /// 读一个文件夹的第一层（隐藏文件不算；只在 iCloud 云端的占位文件、读不出信息的文件不进列表，只计数）。
    /// 文件夹顺带数一下里面第一层有几项。会阻塞，不要在主线程调用。
    static func scan(_ folder: String) -> [OrganizeCandidate] { scanWithStats(folder).candidates }

    static func scanWithStats(_ folder: String) -> (candidates: [OrganizeCandidate], stats: DownloadsPlanLogic.ScanStats) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        var stats = DownloadsPlanLogic.ScanStats()
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            AppLog.organize.error("organize scan: cannot list folder: \(AppLog.describe(error), privacy: .public)")
            return ([], stats)
        }
        var candidates: [OrganizeCandidate] = []
        for file in urls {
            if file.pathExtension == "icloud" || !FileActions.isLocal(file) {
                stats.cloudOnly += 1
                continue
            }
            guard let item = FileItem(url: file) else {
                stats.unreadable += 1
                continue
            }
            var candidate = OrganizeCandidate(item: item)
            if item.isDirectory {
                candidate.childCount = (try? fm.contentsOfDirectory(at: file, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles]))?.count
            }
            candidates.append(candidate)
        }
        return (candidates, stats)
    }

    /// 按勾选的计划移动 / 移到废纸篓。只移动、不覆盖：目标位置这时有了同名文件就再换一个编号。会阻塞。
    static func run(_ items: [DownloadsPlanLogic.PlanItem], now: Date = Date()) -> DownloadsOrganizeOutcome {
        let fm = FileManager.default
        var outcome = DownloadsOrganizeOutcome()
        for item in items {
            let c = item.candidate
            let url = URL(fileURLWithPath: c.path)
            // 预览以后又开始下载 / 被改动 / 被移走的，跳过。
            guard fm.fileExists(atPath: c.path), let fresh = FileItem(url: url),
                  DownloadsPlanLogic.isInProgress(OrganizeCandidate(item: fresh), now: Date()) == nil else {
                outcome.gone.append(c.name)
                continue
            }
            switch item.target {
            case .trash:
                var resulting: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    outcome.trashed.append((from: c.path, to: resulting?.path, size: fresh.size))
                } catch {
                    outcome.failed.append(c.name)
                }
            case .folder(let folder):
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: folder, isDirectory: &isDir) {
                    // 只新建按类型分组的子文件夹；规则的目标文件夹不在了就跳过（不在旧位置冒出一个同名文件夹）。
                    guard item.createsFolder, (try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil else {
                        outcome.failed.append(c.name)
                        continue
                    }
                    outcome.createdFolders.append(folder)
                } else if !isDir.boolValue {
                    outcome.failed.append(c.name)
                    continue
                }
                let target = OrganizeEngine.uniqueURL(for: c.name, in: URL(fileURLWithPath: folder, isDirectory: true))
                do {
                    try fm.moveItem(at: url, to: target)
                    outcome.moved.append((from: c.path, to: target.path, size: fresh.size))
                } catch {
                    outcome.failed.append(c.name)
                }
            }
        }
        return outcome
    }
}

@MainActor
final class DownloadsOrganizeModel: ObservableObject {
    enum Mode: String, CaseIterable, Hashable {
        case preview
        case group
    }

    enum Phase {
        case loading
        case ready
        case running
        case done(DownloadsOrganizeOutcome)
    }

    @Published var folder: String
    @Published var mode: Mode = .preview
    @Published var groupMode: DownloadsPlanLogic.GroupMode = .type
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var candidates: [OrganizeCandidate] = []
    @Published private(set) var plan = DownloadsPlanLogic.Plan()
    @Published private(set) var stats = DownloadsPlanLogic.ScanStats()
    @Published var unchecked: Set<String> = []
    /// 确认整理后注册到撤销栈的那一项（「撤销全部」用）。
    @Published private(set) var undoAction: FileUndoAction?
    @Published private(set) var undone = false
    private var loadGeneration = 0

    init(folder: String) {
        self.folder = folder
        if Demo.isOn && Demo.page == "organize-group" { mode = .group }
    }

    var checkedItems: [DownloadsPlanLogic.PlanItem] {
        plan.items.filter { !unchecked.contains($0.id) }
    }

    var groups: [DownloadsPlanLogic.TargetGroup] { DownloadsPlanLogic.groupByTarget(plan.items) }

    var displayGroups: [DownloadsPlanLogic.DisplayGroup] {
        DownloadsPlanLogic.group(candidates, by: groupMode, now: Date())
    }

    var downloadingCount: Int {
        plan.skipped.values.filter { $0 != .folder }.count
    }

    var skippedFolderCount: Int { DownloadsPlanLogic.skipCounts(plan).folders }

    /// 预览为空时为什么空（有要整理的文件时为 nil）。
    var emptyExplanation: DownloadsPlanLogic.EmptyExplanation? {
        DownloadsPlanLogic.explainEmpty(plan, candidates: candidates, stats: stats)
    }

    func load(rules: [OrganizeRule], ignored: [String], isPro: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        undoAction = nil
        undone = false
        let folder = folder
        // 不是 Pro 时规则不生效，只按类型分组。
        let planRules = isPro ? rules.compactMap(\.planRule) : []
        let ignoredSet = Set(ignored)
        Task {
            let (found, stats, plan) = await Task.detached(priority: .userInitiated) {
                let (found, stats) = DownloadsOrganizeEngine.scanWithStats(folder)
                let fm = FileManager.default
                let plan = DownloadsPlanLogic.plan(found, in: folder, rules: planRules, ignored: ignoredSet, now: Date()) {
                    fm.fileExists(atPath: $0)
                }
                AppLog.organize.info("\(DownloadsPlanLogic.logLine(found: found.count, stats: stats, plan: plan), privacy: .public)")
                return (found, stats, plan)
            }.value
            guard generation == loadGeneration else { return }
            candidates = found
            self.stats = stats
            self.plan = plan
            unchecked = Set(plan.items.filter { !$0.checked }.map(\.id))
            phase = .ready
        }
    }

    func toggle(_ id: String) {
        if unchecked.contains(id) { unchecked.remove(id) } else { unchecked.insert(id) }
    }

    func setGroup(_ group: DownloadsPlanLogic.TargetGroup, checked: Bool) {
        let ids = group.items.map(\.id)
        if checked { unchecked.subtract(ids) } else { unchecked.formUnion(ids) }
    }

    func confirm(store: LibraryStore) {
        let items = checkedItems
        guard !items.isEmpty else { return }
        phase = .running
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { DownloadsOrganizeEngine.run(items) }.value
            record(outcome, store: store)
            phase = .done(outcome)
        }
    }

    /// 记进「清理记录」（一批），注册到主窗口撤销栈，更新主窗口列表。
    private func record(_ outcome: DownloadsOrganizeOutcome, store: LibraryStore) {
        guard outcome.count > 0 else { return }
        let batch = UUID()
        let now = Date()
        var records: [CleanupRecord] = []
        for file in outcome.moved {
            let destination = (file.to as NSString).deletingLastPathComponent
            var record = CleanupRecord(batchID: batch, date: now, action: .moveOut, name: (file.from as NSString).lastPathComponent,
                                       originalPath: file.from, currentPath: file.to, size: file.size,
                                       destinationName: FileManager.default.displayName(atPath: destination),
                                       destinationRoot: destination, aliasPath: nil)
            let identity = CleanupHistoryLogic.identity(atPath: file.to)
            record.fileNumber = identity.number
            record.fileBytes = identity.bytes
            records.append(record)
            ShelfStore.shared.relocate(from: file.from, to: URL(fileURLWithPath: file.to))
            ReminderStore.shared.relocate(from: file.from, to: file.to)
        }
        for file in outcome.trashed {
            var record = CleanupRecord(batchID: batch, date: now, action: .trash, name: (file.from as NSString).lastPathComponent,
                                       originalPath: file.from, currentPath: file.to, size: file.size)
            if let to = file.to {
                let identity = CleanupHistoryLogic.identity(atPath: to)
                record.fileNumber = identity.number
                record.fileBytes = identity.bytes
            }
            records.append(record)
        }
        CleanupHistory.shared.add(records)
        store.forget(paths: Set(outcome.moved.map(\.from) + outcome.trashed.map(\.from)))
        store.filesChanged()
        undoAction = FileUndoCenter.shared.registerHistory(
            batch: batch, name: String(localized: "整理下载"),
            toast: String(localized: "已整理 \(outcome.count) 个文件"),
            createdFolders: outcome.createdFolders
        )
    }

    /// 「撤销全部」：和 ⌘Z、小提示上的「撤销」是同一个操作。
    func undoAll() {
        guard let undoAction, !undoAction.isUndone else { return }
        FileUndoCenter.shared.undoFromToast(undoAction)
        undone = true
    }
}

// MARK: - 界面

/// 打开「整理下载」面板的按钮（下载来源页、自动整理页都放一个）。
struct OrganizeDownloadsButton: View {
    /// 演示模式 --page=organize 截图时直接打开面板。
    @State private var showing = Demo.isOn && Demo.page.hasPrefix("organize")
    var folder: String = Demo.isOn ? Demo.downloadsFolder.path : Folders.downloads

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("整理下载…", systemImage: "wand.and.stars")
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .help("先预览每个文件会移到哪里，确认后才移动；也可以只分组看看")
        .sheet(isPresented: $showing) {
            DownloadsOrganizeSheet(folder: folder)
        }
    }
}

struct DownloadsOrganizeSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var organizer: AutoOrganizer
    @EnvironmentObject private var license: LicenseManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DownloadsOrganizeModel

    init(folder: String) {
        _model = StateObject(wrappedValue: DownloadsOrganizeModel(folder: folder))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 680, height: 580)
        .onAppear(perform: reload)
        .onChange(of: model.folder) { reload() }
        // 在面板开着时开始试用 / 激活：重新算一遍去向（Pro 的自动整理规则生效），按钮变回「确认整理」。
        .onChange(of: license.isPro) {
            if case .ready = model.phase { reload() }
        }
    }

    private func reload() {
        model.load(rules: organizer.rules, ignored: organizer.ignored, isPro: license.isPro)
    }

    // MARK: 顶部

    private var folderChoices: [String] {
        var list = [Folders.downloads]
        for rule in organizer.rules where rule.enabled && !list.contains(rule.watchFolder) {
            list.append(rule.watchFolder)
        }
        if !list.contains(model.folder) { list.append(model.folder) }
        return list
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TintedIcon(symbol: "wand.and.stars", tint: .purple, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("整理「\(FileManager.default.displayName(atPath: model.folder))」")
                        .font(.title2.weight(.bold))
                    Text(model.mode == .preview
                         ? String(localized: "先看清楚每个文件会去哪儿，确认后才移动；整理完可以一键撤销。")
                         : String(localized: "只是分组看看，不会移动任何文件。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(folderChoices, id: \.self) { path in
                        Button(FileManager.default.displayName(atPath: path)) { model.folder = path }
                    }
                    Divider()
                    Button("选择其他文件夹…") {
                        if let path = RuleEditor.chooseFolder(prompt: String(localized: "整理")) { model.folder = path }
                    }
                } label: {
                    Label(FileManager.default.displayName(atPath: model.folder), systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isBusy)
            }
            HStack {
                Picker("方式", selection: $model.mode) {
                    Text("整理预览").tag(DownloadsOrganizeModel.Mode.preview)
                    Text("只分组显示").tag(DownloadsOrganizeModel.Mode.group)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .disabled(isBusy || isDone)
                if model.mode == .group {
                    Picker("分组", selection: $model.groupMode) {
                        Text("按类型").tag(DownloadsPlanLogic.GroupMode.type)
                        Text("按添加日期").tag(DownloadsPlanLogic.GroupMode.dateAdded)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                Spacer()
                if !license.isPro, model.mode == .preview {
                    Text("免费可预览，开始整理需要 Pro")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    private var isBusy: Bool {
        switch model.phase {
        case .loading, .running: return true
        default: return false
        }
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在读取…")
        case .running:
            ProgressView("正在整理…")
        case .done(let outcome):
            doneView(outcome)
        case .ready:
            if model.mode == .group {
                groupList
            } else if let explanation = model.emptyExplanation {
                emptyView(explanation)
            } else {
                previewList
            }
        }
    }

    private var previewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        groupHeader(group)
                        ForEach(group.items) { item in
                            PlanRow(item: item, checked: !model.unchecked.contains(item.id)) { model.toggle(item.id) }
                        }
                    }
                    .padding(.vertical, 6)
                    .glassCard(radius: 14)
                }
                if model.downloadingCount > 0 {
                    Label("\(model.downloadingCount) 个文件还在下载或几秒内刚改动过（.download、.crdownload、.part 等），这次跳过。", systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.skippedFolderCount > 0 {
                    Label("\(model.skippedFolderCount) 个文件夹不移动：整理只看第一层的文件。", systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.stats.cloudOnly > 0 {
                    Label("\(model.stats.cloudOnly) 个文件只在 iCloud 云端、还没下载到这台 Mac，这次跳过。", systemImage: "icloud")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Label("只移动、不覆盖：同名文件自动加编号。移到废纸篓的随时可以放回。整理记录在「清理记录」里。", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    /// 预览为空：说清楚为什么，第一层只有文件夹时列出来，可以直接在拾掇里打开。
    private func emptyView(_ e: DownloadsPlanLogic.EmptyExplanation) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: e.kind == .onlyFolders ? "folder" : "checkmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("没有需要整理的文件")
                    .font(.title3.weight(.semibold))
                switch e.kind {
                case .emptyFolder:
                    Text("这个文件夹是空的。")
                        .foregroundStyle(.secondary)
                case .onlyFolders:
                    Text("下载第一层只有文件夹，之前整理过的文件在这些子文件夹里")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("整理只看第一层的文件，文件夹本身不移动。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .allSkipped:
                    EmptyView()
                }
                VStack(alignment: .leading, spacing: 6) {
                    if e.kind != .onlyFolders && !e.folders.isEmpty {
                        Label("\(e.folders.count) 个文件夹不移动：整理只看第一层的文件。", systemImage: "folder")
                    }
                    if e.downloading > 0 {
                        Label("\(e.downloading) 个文件还在下载（.download、.crdownload、.part 等），这次跳过。", systemImage: "arrow.down.circle")
                    }
                    if e.justModified > 0 {
                        Label("\(e.justModified) 个文件几秒内刚改动过，可能还在写入，这次跳过。", systemImage: "clock")
                    }
                    if e.cloudOnly > 0 {
                        Label("\(e.cloudOnly) 个文件只在 iCloud 云端、还没下载到这台 Mac，这次跳过。", systemImage: "icloud")
                    }
                    if e.unreadable > 0 {
                        Label("\(e.unreadable) 个文件读不到信息（可能没有权限），这次跳过。", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if !e.folders.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(e.folders) { folder in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(folder.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if let count = folder.childCount {
                                    Text("\(count) 项")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Button("在拾掇中打开") {
                                    let url = URL(fileURLWithPath: folder.path, isDirectory: true)
                                    dismiss()
                                    store.openFolder(url)
                                }
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.vertical, 6)
                    .glassCard(radius: 14)
                    .frame(maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private func groupHeader(_ group: DownloadsPlanLogic.TargetGroup) -> some View {
        let allChecked = group.items.allSatisfy { !model.unchecked.contains($0.id) }
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { allChecked }, set: { model.setGroup(group, checked: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            switch group.target {
            case .trash:
                Image(systemName: "trash").foregroundStyle(.orange)
                Text("移到废纸篓").fontWeight(.semibold)
            case .folder(let path):
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text("移到「\(FileManager.default.displayName(atPath: path))」").fontWeight(.semibold)
                if group.items.contains(where: \.createsFolder) {
                    Text("新建")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Text(Self.shortPath(path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text("\(group.items.count) 个")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    static func shortPath(_ path: String) -> String {
        if Demo.isOn, path.hasPrefix(Demo.folder.path) { return "~" + path.dropFirst(Demo.folder.path.count) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var groupList: some View {
        let groups = model.displayGroups
        return Group {
            if groups.isEmpty {
                ContentUnavailableView("这个文件夹是空的", systemImage: "tray")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text(group.title).fontWeight(.semibold)
                                    Spacer()
                                    Text("\(group.items.count) 个 · \(group.items.reduce(Int64(0)) { $0 + $1.size }.byteText)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                ForEach(group.items) { c in
                                    CandidateRow(candidate: c)
                                }
                            }
                            .padding(.vertical, 6)
                            .glassCard(radius: 14)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func doneView(_ outcome: DownloadsOrganizeOutcome) -> some View {
        VStack(spacing: 14) {
            Image(systemName: model.undone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(model.undone ? Color.secondary : Color.green)
            Text(model.undone ? String(localized: "已撤销，文件正在放回原处") : String(localized: "已整理 \(outcome.count) 个文件"))
                .font(.title3.weight(.semibold))
            if !outcome.moved.isEmpty || !outcome.trashed.isEmpty {
                Text("移动 \(outcome.moved.count) 个 · 移到废纸篓 \(outcome.trashed.count) 个")
                    .foregroundStyle(.secondary)
            }
            if !outcome.gone.isEmpty {
                Text("\(outcome.gone.count) 个已经不在、或又开始下载了，没有动：\(FileUndoLogic.names(outcome.gone))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !outcome.failed.isEmpty {
                Text("\(outcome.failed.count) 个没能移动（目标文件夹不在了或没有权限）：\(FileUndoLogic.names(outcome.failed))")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if model.undoAction != nil, !model.undone {
                Button {
                    model.undoAll()
                } label: {
                    Label("撤销全部", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.large)
                Text("也可以按 ⌘Z，或在「清理记录」里一个个放回。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(30)
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            if case .ready = model.phase, model.mode == .preview, !model.plan.items.isEmpty {
                let checked = model.checkedItems
                let trash = checked.filter { $0.target == .trash }.count
                Text(trash > 0
                     ? String(localized: "将移动 \(checked.count - trash) 个，移到废纸篓 \(trash) 个")
                     : String(localized: "将移动 \(checked.count) 个文件"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDone {
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if model.mode == .preview {
                    if license.isPro {
                        Button("确认整理") { model.confirm(store: store) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isBusy || model.checkedItems.isEmpty)
                    } else {
                        // 免费版：预览和「只分组显示」照常用；真正移动文件是 Pro，按钮带小锁，点了弹拾掇 Pro 介绍页。
                        Button {
                            license.showPaywall = true
                        } label: {
                            Label("开始整理 · Pro", systemImage: "lock.fill")
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBusy || model.checkedItems.isEmpty)
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct PlanRow: View {
    let item: DownloadsPlanLogic.PlanItem
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { checked }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.candidate.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.candidate.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let target = item.targetPath, (target as NSString).lastPathComponent != item.candidate.name {
                    Text("同名，改为「\((target as NSString).lastPathComponent)」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.previouslyUndone {
                Text("之前撤销过")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(item.ruleName.map { String(localized: "规则：\($0)") } ?? String(localized: "按类型"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.candidate.size.byteText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(checked ? 1 : 0.55)
    }
}

private struct CandidateRow: View {
    let candidate: OrganizeCandidate

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(candidate.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let date = candidate.addedDate {
                Text(date.shortText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.isDirectory ? "--" : candidate.size.byteText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
        }
        .help("连按两次在访达中显示")
    }
}
