import AppKit
import SwiftUI

/// 一次搬家的状态：选目标 → 搬 → 结果。
@MainActor
final class MoveOutJob: ObservableObject {
    enum Phase {
        case choosing
        case preparing
        case running
        case finished
    }

    @Published var phase: Phase = .choosing
    @Published var progress: MoveOutProgress?
    @Published var result: MoveOutResult?
    @Published var batch: UUID?
    /// 没法开始的原因（空间不够、只读磁盘……），显示在面板里。
    @Published var errorText: String?
    private var flag = MoveOutCancelFlag()

    func cancel() { flag.cancel() }

    func start(items: [FileItem], destination: MoveDestination, keepAlias: Bool, keepStructure: Bool,
               store: LibraryStore) {
        flag = MoveOutCancelFlag()
        let cancel = flag
        errorText = nil
        phase = .preparing
        let options = MoveOutOptions(destinationRoot: destination.path, destinationName: destination.name,
                                     keepAlias: keepAlias, keepStructure: keepStructure,
                                     folderName: String(localized: "拾掇搬家"))
        let raw = items.map { MoveOutSource(path: $0.path, name: $0.name, size: $0.size, isDirectory: $0.isDirectory) }
        Task {
            // 文件夹的大小可能还没算，后台补上。
            let sources: [MoveOutSource] = await Task.detached(priority: .userInitiated) {
                raw.map { (source: MoveOutSource) -> MoveOutSource in
                    guard source.isDirectory || source.size <= 0 else { return source }
                    let real = MoveOutEngine.logicalSize(URL(fileURLWithPath: source.path))
                    return MoveOutSource(path: source.path, name: source.name, size: real, isDirectory: source.isDirectory)
                }
            }.value
            let need = MoveOutEngine.requiredBytes(sources, destination: destination.url)
            let free = destination.availableBytes
            if need > 0, need > free {
                phase = .choosing
                errorText = String(localized: "「\(destination.name)」空间不够：需要 \(need.byteText)，只剩 \(free.byteText)。")
                return
            }
            phase = .running
            let result = await Task.detached(priority: .userInitiated) {
                MoveOutEngine.run(sources, options: options, cancel: cancel) { snapshot in
                    Task { @MainActor [weak self] in self?.progress = snapshot }
                }
            }.value
            finish(result, destination: destination, store: store)
        }
    }

    private func finish(_ result: MoveOutResult, destination: MoveDestination, store: LibraryStore) {
        self.result = result
        if !result.moved.isEmpty {
            let batch = UUID()
            let now = Date()
            CleanupHistory.shared.add(result.moved.map {
                var record = CleanupRecord(batchID: batch, date: now, action: .moveOut, name: $0.name, originalPath: $0.from,
                                           currentPath: $0.to, size: $0.size, destinationName: destination.name,
                                           destinationRoot: destination.path, aliasPath: $0.aliasPath)
                let identity = CleanupHistoryLogic.identity(atPath: $0.to)
                record.fileNumber = identity.number
                record.fileBytes = identity.bytes
                return record
            })
            self.batch = batch
            store.forget(paths: Set(result.moved.map(\.from)))
            for file in result.moved { FolderIconService.shared.movePath(file.from, to: file.to) }
        }
        phase = .finished
    }
}

/// 「搬到…」面板：选一个目标，把大文件搬过去，原处可以留一个替身。
struct MoveOutSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let items: [FileItem]

    @StateObject private var job = MoveOutJob()
    @State private var destinations: [MoveDestination] = []
    @State private var selectedPath: String?
    @State private var keepAlias = MoveOutSettings.keepAlias
    @State private var keepStructure = MoveOutSettings.keepStructure

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    private var selected: MoveDestination? { destinations.first { $0.path == selectedPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("搬到其他地方")
                    .font(.title2.bold())
                ProBadge()
            }
            switch job.phase {
            case .choosing, .preparing:
                chooser
            case .running:
                running
            case .finished:
                finished
            }
        }
        .padding(22)
        .frame(width: 580)
        .onAppear(perform: loadDestinations)
    }

    // MARK: 选目标

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1
                 ? String(localized: "「\(items[0].name)」· \(totalBytes.byteText)")
                 : String(localized: "\(items.count) 个项目 · 共 \(totalBytes.byteText)"))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                if destinations.isEmpty {
                    Text("没有找到移动硬盘、NAS 或网盘文件夹。接上移动硬盘，或者点「选择文件夹…」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(destinations) { destination in
                    destinationRow(destination)
                }
            }

            Button {
                chooseFolder()
            } label: {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("在原位置留替身", isOn: $keepAlias)
                Text("原来的位置会留一个访达替身，双击它就能打开搬走的文件（目标盘要连着）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("按原文件夹分类存放", isOn: $keepStructure)
                Text(keepStructure
                     ? String(localized: "放在目标里的「拾掇搬家/原文件夹名」下。")
                     : String(localized: "直接放在目标文件夹里。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = job.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let selected, selected.isSyncFolder {
                Label("iCloud 和网盘同步文件夹也在这台 Mac 的磁盘上：要等上传完成，再在访达里右键「移除下载」，才会真正腾出空间。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("跨盘时先完整拷贝、核对大小，再删除原文件；出错会保留原文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    if job.phase == .preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("开始搬家")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || job.phase == .preparing)
            }
        }
    }

    private func destinationRow(_ destination: MoveDestination) -> some View {
        let isSelected = destination.path == selectedPath
        return HStack(spacing: 12) {
            Image(systemName: destination.symbol)
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(destination.kindText) · 可用 \(destination.availableBytes.byteText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { selectedPath = destination.path }
        .help(destination.path)
    }

    // MARK: 搬家中

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            let p = job.progress
            let fraction = (p?.bytesTotal ?? 0) > 0 ? Double(p?.bytesDone ?? 0) / Double(p?.bytesTotal ?? 1) : 0
            ProgressView(value: min(max(fraction, 0), 1))
            if let p {
                Text("正在搬第 \(min(p.fileIndex + 1, p.fileCount)) / \(p.fileCount) 个：\(p.currentName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(p.bytesDone.byteText) / \(p.bytesTotal.byteText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("正在准备…")
            }
            HStack {
                Text("取消后，已经搬完的文件留在新位置（可以在「清理记录」里放回），没搬完的保持原样。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { job.cancel() }
            }
        }
    }

    // MARK: 结果

    private var finished: some View {
        let result = job.result ?? MoveOutResult()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: result.moved.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(result.moved.isEmpty ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "已搬走 \(result.moved.count) 个文件，腾出 \(result.freedBytes.byteText)"))
                        .font(.headline)
                    if result.cancelled {
                        Text("搬家已取消。").foregroundStyle(.secondary)
                    }
                }
            }
            if !result.moved.isEmpty, result.freedBytes == 0 {
                Text("目标和原文件在同一块磁盘上，这台 Mac 暂时没有腾出空间。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !result.skipped.isEmpty {
                Text(String(localized: "跳过 \(result.skipped.count) 个（已是替身、只在 iCloud 云端或已在目标里）：\(result.skipped.prefix(5).joined(separator: String(localized: "、")))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !result.failed.isEmpty {
                Text(String(localized: "\(result.failed.count) 个没搬成，原文件还在：\(result.failed.prefix(5).joined(separator: String(localized: "、")))"))
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if !result.aliasFailed.isEmpty {
                Text(String(localized: "\(result.aliasFailed.count) 个已经搬走，但原位置没能留下替身，要去新位置打开：\(result.aliasFailed.prefix(5).joined(separator: String(localized: "、")))"))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("30 天内可以在「清理记录」里把它们搬回原处。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let batch = job.batch {
                    Button("撤销这次搬家") {
                        dismiss()
                        store.undoBatch(batch)
                    }
                }
                Spacer()
                if !result.moved.isEmpty {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting(result.moved.map { URL(fileURLWithPath: $0.to) })
                    }
                }
                Button("完成") {
                    dismiss()
                    store.filesChanged()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 动作

    private func loadDestinations() {
        var list = MoveDestinations.detect(volumes: store.volumes.volumes)
        for path in MoveOutSettings.customFolders where FileManager.default.fileExists(atPath: path) {
            if !list.contains(where: { $0.path == path }) {
                list.append(MoveDestination(kind: .custom, name: FileManager.default.displayName(atPath: path), path: path))
            }
        }
        destinations = list
        if let last = MoveOutSettings.lastDestination, list.contains(where: { $0.path == last }) {
            selectedPath = last
        } else if selectedPath == nil {
            selectedPath = list.first { $0.kind == .external || $0.kind == .network }?.path
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "搬到这里")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        var custom = MoveOutSettings.customFolders.filter { $0 != path }
        custom.insert(path, at: 0)
        MoveOutSettings.customFolders = custom
        if !destinations.contains(where: { $0.path == path }) {
            destinations.append(MoveDestination(kind: .custom, name: FileManager.default.displayName(atPath: path), path: path))
        }
        selectedPath = path
    }

    private func start() {
        guard let destination = selected else { return }
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            job.errorText = String(localized: "无法写入「\(destination.name)」：可能是只读磁盘（例如 NTFS 格式的移动硬盘）或没有权限。")
            return
        }
        MoveOutSettings.lastDestination = destination.path
        MoveOutSettings.keepAlias = keepAlias
        MoveOutSettings.keepStructure = keepStructure
        job.start(items: items, destination: destination, keepAlias: keepAlias, keepStructure: keepStructure, store: store)
    }
}
