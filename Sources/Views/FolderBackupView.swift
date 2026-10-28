import AppKit
import SwiftUI

// MARK: - 备份到硬盘页

/// 侧边栏「整理 › 备份到硬盘」（拾掇 Pro）：Mac 文件夹 ↔ 移动硬盘文件夹的配对列表。
/// 免费用户看得到页面和说明，但不能添加、打开或备份。
struct FolderBackupView: View {
    @ObservedObject private var backups = FolderBackupStore.shared
    @EnvironmentObject private var license: LicenseManager
    @State private var addError: String?

    private struct PreviewTarget: Identifiable { let id: UUID }

    private var previewBinding: Binding<PreviewTarget?> {
        Binding(get: { backups.previewPairID.map(PreviewTarget.init) },
                set: { backups.previewPairID = $0?.id })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !license.isPro {
                        ProHintRow()
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    }
                    if let notice = backups.notice {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                            Text(notice)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                backups.notice = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    }
                    if backups.pairs.isEmpty {
                        emptyState
                    } else {
                        ForEach(backups.pairs) { pair in
                            BackupPairCard(pairID: pair.id)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
        .navigationTitle("备份到硬盘")
        .onAppear { backups.refreshAll() }
        .sheet(item: previewBinding) { target in
            FolderBackupPreviewSheet(pairID: target.id)
        }
        .alert("没能添加配对", isPresented: errorBinding) {
            Button("好") { addError = nil }
        } message: {
            Text(addError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("备份到硬盘")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    ProBadge()
                }
                Text("把 Mac 上的文件夹单向备份到移动硬盘：只从 Mac 拷到硬盘，从不把硬盘里的东西拷回 Mac；默认不删除硬盘上的文件。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                addPair()
            } label: {
                Label("添加配对…", systemImage: "plus")
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .disabled(!license.isPro)
            .help("先选 Mac 上要备份的文件夹，再选移动硬盘上放备份的文件夹")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("还没有配对", systemImage: "externaldrive.badge.plus")
                .font(.headline)
            Text("1. 接上移动硬盘，点右上角「添加配对…」，先选 Mac 上的文件夹，再选硬盘上的文件夹（也可以在文件夹上点右键「备份到硬盘…」）。")
            Text("2. 打开这一组的开关。开关默认是关的，打开以前什么都不会拷。")
            Text("3. 以后每次插上这块硬盘，拾掇会提示「有 N 个新文件/改动要备份」，先预览、再点备份。")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private func addPair() {
        if let error = FolderBackupPicker.startPair(mac: nil) {
            addError = error
        }
    }
}

// MARK: - 一组配对

private struct BackupPairCard: View {
    let pairID: UUID
    @ObservedObject private var backups = FolderBackupStore.shared
    @EnvironmentObject private var license: LicenseManager
    @State private var confirmRemove = false

    var body: some View {
        if let pair = backups.pair(pairID) {
            card(pair, status: backups.status(pairID))
        }
    }

    private func card(_ pair: BackupPair, status: BackupPairStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: pair.macPath))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.macName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(pair.macPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 120, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .help("只从 Mac 拷到硬盘")
                Image(systemName: status.isConnected ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                    .font(.title2)
                    .foregroundStyle(status.isConnected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.driveLabel)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status.isConnected ? String(localized: "已接上 · 剩余 \(status.freeBytes.byteText)") : String(localized: "硬盘没接上"))
                        .font(.caption)
                        .foregroundStyle(status.isConnected ? Color.green : Color.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { pair.enabled }, set: { backups.setEnabled(pairID, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!license.isPro)
                    .help("打开后，插上这块硬盘时才会检查和提示；关着时什么都不拷")
            }

            Text(statusLine(pair, status: status))
                .font(.callout)
                .foregroundStyle(status.macMissing ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if backups.running?.pairID == pairID {
                BackupProgressCard(floating: false, width: 520)
            } else {
                HStack(spacing: 8) {
                    Button("预览…") { backups.previewPairID = pairID }
                        .disabled(status.plan == nil)
                    Button("立即备份") { backups.backup(pairID, includeDeletes: false, announce: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(backups.blocker(pairID) != nil || !(status.plan?.hasWork ?? false))
                        .help(backups.blocker(pairID) ?? String(localized: "把新文件和改动拷到硬盘（不删除硬盘上的文件）"))
                    Button("重新检查") { backups.refresh(pairID) }
                        .disabled(!pair.enabled || !license.isPro || status.scanning)
                    if status.scanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Menu("更多") {
                        Button("在访达中显示 Mac 文件夹") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pair.macPath)])
                        }
                        .disabled(status.macMissing)
                        if let root = status.driveRoot {
                            Button("在访达中显示硬盘文件夹") {
                                let url = URL(fileURLWithPath: root)
                                if FileManager.default.fileExists(atPath: root) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.volumeMount ?? root)])
                                }
                            }
                        }
                        Divider()
                        Button("移除配对…", role: .destructive) { confirmRemove = true }
                    }
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("插上就自动备份", isOn: Binding(get: { pair.autoBackupOnMount },
                                                 set: { backups.setAutoBackup(pairID, $0) }))
                    .help("插上这块硬盘后不再提示，直接把新文件和改动拷过去；自动备份从不删除硬盘上的文件")
                Toggle(isOn: Binding(get: { pair.mirrorDeletes }, set: { backups.setMirror(pairID, $0) })) {
                    Text("镜像：删除硬盘上 Mac 已删除的文件")
                        .foregroundStyle(pair.mirrorDeletes ? Color.red : Color.primary)
                }
                .help("打开后，预览里可以把只在硬盘上的项目移到硬盘的废纸篓，每次都要再确认；插上自动备份、通知上的「备份」都不会删")
                if pair.mirrorDeletes {
                    Text("每次删除前都会用红色确认框列出个数；删掉的项目进硬盘自己的废纸篓，清倒以前还能找回。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .disabled(!license.isPro)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .opacity(pair.enabled ? 1 : 0.85)
        .alert("移除这组配对？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { backups.remove(pairID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只是不再备份，Mac 和硬盘上的文件都不会动。")
        }
    }

    private func statusLine(_ pair: BackupPair, status: BackupPairStatus) -> String {
        var parts: [String] = []
        if status.macMissing {
            parts.append(String(localized: "Mac 上的文件夹找不到了，先把它放回原处"))
        } else if !pair.enabled {
            parts.append(String(localized: "已关闭：打开开关后才会检查和备份"))
        } else if !status.isConnected {
            if let pending = pair.lastPending, pending > 0 {
                parts.append(String(localized: "上次检查还有 \(pending) 个没备份"))
            }
        } else if status.scanning {
            parts.append(String(localized: "正在比较两边…"))
        } else if let plan = status.plan {
            if plan.pendingCount == 0 {
                parts.append(String(localized: "已是最新"))
            } else {
                parts.append(String(localized: "待备份 \(plan.pendingCount) 个（\(plan.bytesToCopy.byteText)）"))
            }
            if plan.onlyOnDriveFileCount > 0 || !plan.onlyOnDrive.isEmpty {
                parts.append(String(localized: "只在硬盘上 \(plan.onlyOnDrive.count) 项"))
            }
            if status.cloudOnly > 0 {
                parts.append(String(localized: "\(status.cloudOnly) 个只在 iCloud 里的文件跳过"))
            }
            if !FolderBackupLogic.hasEnoughSpace(required: FolderBackupLogic.requiredBytes(plan), available: status.freeBytes) {
                parts.append(String(localized: "硬盘空间不够"))
            }
        }
        if let last = pair.lastBackup {
            parts.append(String(localized: "上次备份：\(last.formatted(.relative(presentation: .named)))"))
        } else {
            parts.append(String(localized: "还没备份过"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 预览

/// 先看要做什么：新文件 / 改动 / 只在硬盘上（/ 类型不同）。确认后才备份。
struct FolderBackupPreviewSheet: View {
    let pairID: UUID
    @ObservedObject private var backups = FolderBackupStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .new
    @State private var deleteToo = false
    @State private var confirmDelete = false

    enum Tab: Hashable { case new, changed, onlyOnDrive, conflicts }

    /// 列表最多画这么多行（再多只显示「还有 N 项」）。
    private let rowLimit = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pair = backups.pair(pairID) {
                content(pair, status: backups.status(pairID))
            }
        }
        .padding(20)
        .frame(width: 640, height: 540)
    }

    @ViewBuilder
    private func content(_ pair: BackupPair, status: BackupPairStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("备份预览")
                .font(.title2.weight(.semibold))
            Text("「\(pair.macName)」→「\(status.volumeName ?? pair.volumeName)」，只从 Mac 拷到硬盘")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if let plan = status.plan {
            Picker("", selection: $tab) {
                Text("新文件 \(plan.newFiles.count)").tag(Tab.new)
                Text("改动 \(plan.changed.count)").tag(Tab.changed)
                Text("只在硬盘上 \(plan.onlyOnDrive.count)").tag(Tab.onlyOnDrive)
                if !plan.conflicts.isEmpty {
                    Text("类型不同 \(plan.conflicts.count)").tag(Tab.conflicts)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            list(plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(tabNote(plan, pair: pair))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let required = FolderBackupLogic.requiredBytes(plan)
            let enough = FolderBackupLogic.hasEnoughSpace(required: required, available: status.freeBytes)
            Text(enough
                 ? String(localized: "要拷贝 \(plan.bytesToCopy.byteText)，硬盘剩余 \(status.freeBytes.byteText)")
                 : String(localized: "硬盘空间不够：要 \(required.byteText)（另留一点余量），只剩 \(status.freeBytes.byteText)"))
                .font(.callout)
                .foregroundStyle(enough ? Color.secondary : Color.red)

            if pair.mirrorDeletes, !plan.onlyOnDrive.isEmpty {
                Toggle(isOn: $deleteToo) {
                    Text("这次也把只在硬盘上的 \(plan.onlyOnDrive.count) 项（含 \(plan.onlyOnDriveFileCount) 个文件）移到硬盘的废纸篓")
                        .foregroundStyle(.red)
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("以后") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(deleteToo && pair.mirrorDeletes
                       ? String(localized: "备份并删除…")
                       : String(localized: "备份 \(plan.pendingCount) 个文件")) {
                    if deleteToo, pair.mirrorDeletes, !plan.onlyOnDrive.isEmpty {
                        confirmDelete = true
                    } else {
                        start(includeDeletes: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(backups.blocker(pairID) != nil
                          || !(plan.hasWork || (deleteToo && pair.mirrorDeletes && !plan.onlyOnDrive.isEmpty)))
                .help(backups.blocker(pairID) ?? "")
            }
            .alert("把硬盘上的 \(plan.onlyOnDrive.count) 项移到废纸篓？", isPresented: $confirmDelete) {
                Button("移到废纸篓并备份", role: .destructive) { start(includeDeletes: true) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些项目在 Mac 上已经删掉了（共 \(plan.onlyOnDriveFileCount) 个文件）。它们会被移到「\(status.volumeName ?? pair.volumeName)」自己的废纸篓，清倒以前还能找回；Mac 上的文件不受影响。")
            }
        } else if status.scanning {
            Spacer()
            HStack {
                Spacer()
                ProgressView("正在比较两边…")
                Spacer()
            }
            Spacer()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
            }
        } else {
            Spacer()
            Text(backups.blocker(pairID) ?? String(localized: "还没有比较结果"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let size: Int64?
        let note: String?
        let isFolder: Bool
    }

    private func rows(_ plan: BackupPlan) -> [Row] {
        switch tab {
        case .new:
            return plan.newFiles.map { Row(id: $0.path, size: $0.size, note: nil, isFolder: false) }
        case .changed:
            return plan.changed.map {
                Row(id: $0.mac.path, size: $0.mac.size,
                    note: $0.driveIsNewer ? String(localized: "硬盘上那份更新，会被 Mac 上的覆盖") : nil, isFolder: false)
            }
        case .onlyOnDrive:
            return plan.onlyOnDrive.map {
                Row(id: $0.path, size: $0.kind == .folder ? nil : $0.size, note: nil, isFolder: $0.kind == .folder)
            }
        case .conflicts:
            return plan.conflicts.map { Row(id: $0, size: nil, note: String(localized: "一边是文件夹、一边是文件，跳过"), isFolder: false) }
        }
    }

    @ViewBuilder
    private func list(_ plan: BackupPlan) -> some View {
        let all = rows(plan)
        if all.isEmpty {
            Text(tab == .onlyOnDrive ? String(localized: "没有只在硬盘上的项目") : String(localized: "没有"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        } else {
            List {
                ForEach(all.prefix(rowLimit)) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.isFolder ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(row.id)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = row.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if let size = row.size {
                            Text(size.byteText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if all.count > rowLimit {
                    Text("还有 \(all.count - rowLimit) 项…")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func tabNote(_ plan: BackupPlan, pair: BackupPair) -> String {
        switch tab {
        case .new: return String(localized: "Mac 上有、硬盘上没有的文件，会拷到硬盘上同样的位置。")
        case .changed: return String(localized: "大小或修改时间不一样的文件：用 Mac 上的版本替换硬盘上的（先拷完整再替换，中途拔盘旧版本也还在）。")
        case .onlyOnDrive:
            return pair.mirrorDeletes
                ? String(localized: "这些只在硬盘上（Mac 上已删除或从没有过）。镜像已打开：勾选下面一项才会移到硬盘的废纸篓；不会拷回 Mac。")
                : String(localized: "这些只在硬盘上（Mac 上已删除或从没有过）。不会删除，也不会拷回 Mac。")
        case .conflicts: return String(localized: "同一个名字一边是文件夹、一边是文件，要删掉一边才能对上，所以跳过不动。")
        }
    }

    private func start(includeDeletes: Bool) {
        backups.backup(pairID, includeDeletes: includeDeletes, announce: false)
        dismiss()
    }
}

// MARK: - 添加配对

@MainActor
enum FolderBackupPicker {
    /// 添加配对：mac 为 nil 时先选 Mac 文件夹；再选硬盘上的文件夹。出错返回原因（用户取消返回 nil）。
    /// 成功后切到「备份到硬盘」页。
    @discardableResult
    static func startPair(mac: URL?) -> String? {
        guard LicenseManager.shared.isPro else {
            MainWindow.show { LicenseManager.shared.showPaywall = true }
            return nil
        }
        let externals = FolderBackupStore.mountedVolumes().filter(\.isExternal)
        guard let first = externals.first else {
            return String(localized: "没有找到接着的移动硬盘：先把硬盘接上，再选硬盘上的文件夹。")
        }
        let macFolder: URL
        if let mac {
            macFolder = mac
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.message = String(localized: "选择要备份的 Mac 文件夹")
            panel.prompt = String(localized: "选这个文件夹")
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            macFolder = url
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: externals.count == 1 ? first.mountPath : "/Volumes", isDirectory: true)
        panel.message = String(localized: "选择移动硬盘上放「\(macFolder.lastPathComponent)」备份的文件夹（可以新建一个）")
        panel.prompt = String(localized: "备份到这里")
        guard panel.runModal() == .OK, let drive = panel.url else { return nil }
        if let error = FolderBackupStore.shared.addPair(mac: macFolder, drive: drive) {
            return error
        }
        FolderBackupStore.shared.notice = String(localized: "已添加配对「\(macFolder.lastPathComponent)」。打开它的开关后才会检查和备份。")
        LibraryStore.shared?.selection = .folderBackup
        return nil
    }
}
