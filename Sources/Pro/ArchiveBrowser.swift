import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 拾掇 Pro：压缩包浏览。双击 zip / tar / tar.gz（以及系统能读的 7z、rar）像文件夹一样点进去看，
// 空格快速查看、双击打开、拖出来或「解压到…」只解压需要的那几个。压缩包本身不动；
// 预览 / 打开用的文件解压在系统临时文件夹里（一天后自动清掉）。

/// 「双击压缩包时在拾掇里浏览」（设置 › 拾掇 Pro 功能，默认开）。
enum ArchivePrefs {
    static let browseOnDoubleClickKey = "archiveBrowseOnDoubleClick"
    static var browseOnDoubleClick: Bool {
        UserDefaults.standard.object(forKey: browseOnDoubleClickKey) as? Bool ?? true
    }
}

/// 正在浏览的一个压缩包。
@MainActor
final class ArchiveSession: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let badge: String
    @Published private(set) var tree = ArchiveTree(entries: [])
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPath = ""
    @Published private(set) var nodes: [ArchiveNode] = []
    @Published var selection = Set<String>()
    /// 正在解压时的说明（顶部显示小转圈）。
    @Published private(set) var busyMessage: String?
    /// 预览 / 打开 / 拖出用的临时文件夹（每次浏览一个）。
    let cacheDir: URL

    nonisolated static var cacheRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Shiduo-Archives", isDirectory: true)
    }

    init(url: URL) {
        self.url = url
        self.badge = ArchiveKind.badge(forName: url.lastPathComponent)
        self.cacheDir = Self.cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    var name: String { url.lastPathComponent }

    /// 读目录（后台）。顺手清掉一天前留下的临时文件。
    func load() {
        let archiveURL = self.url
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[ArchiveEntry], Error> in
                Self.cleanOldCaches()
                do { return .success(try ArchiveIO.list(archiveURL)) } catch { return .failure(error) }
            }.value
            isLoading = false
            switch result {
            case .success(let entries):
                tree = ArchiveTree(entries: entries)
                enter("")
                if entries.isEmpty { errorMessage = String(localized: "这个压缩包是空的。") }
            case .failure(let error):
                errorMessage = Self.message(for: error)
            }
        }
    }

    nonisolated static func cleanOldCaches() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let dirs = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for dir in dirs {
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: dir) }
        }
    }

    static func message(for error: Error) -> String {
        switch error as? ArchiveError {
        case .encrypted:
            return String(localized: "这个压缩包加了密码，拾掇暂时解不开。可以用「打开方式」交给「归档实用工具」或其他 App。")
        case .failed(let detail):
            return detail.isEmpty ? String(localized: "解压失败。") : String(localized: "解压失败：\(detail)")
        default:
            return String(localized: "拾掇读不了这个压缩包（文件可能损坏，或者系统不支持这种格式）。可以用「打开方式」交给其他 App。")
        }
    }

    // MARK: 浏览

    func enter(_ path: String) {
        currentPath = path
        selection = []
        nodes = tree.children(of: path)
    }

    /// 上一层；已经在最外层时返回 false（由调用方关掉压缩包）。
    @discardableResult
    func goUp() -> Bool {
        guard !currentPath.isEmpty else { return false }
        enter(ArchivePathLogic.parent(of: currentPath))
        return true
    }

    var selectedNodes: [ArchiveNode] { nodes.filter { selection.contains($0.id) } }

    // MARK: 临时解压（预览、打开、拖出）

    nonisolated static func extractToCache(archive: URL, tree: ArchiveTree, path: String, cacheDir: URL) throws -> URL {
        let target = cacheDir.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try ArchiveIO.extract(archive, entries: tree.entries(under: [path]), all: false, into: cacheDir)
        guard FileManager.default.fileExists(atPath: target.path) else { throw ArchiveError.unreadable }
        return target
    }

    /// 解压到临时文件夹，返回位置（已经解过的直接用）。
    func cachedURL(for node: ArchiveNode) async throws -> URL {
        let (archive, snapshot, cache, path) = (self.url, self.tree, self.cacheDir, node.path)
        let slow = (node.size ?? 0) > 20 * 1024 * 1024
        if slow { busyMessage = String(localized: "正在准备「\(node.name)」…") }
        defer { if slow { busyMessage = nil } }
        return try await Task.detached(priority: .userInitiated) {
            try Self.extractToCache(archive: archive, tree: snapshot, path: path, cacheDir: cache)
        }.value
    }

    /// 双击：文件夹点进去；文件解压到临时文件夹后用默认 App 打开。
    func open(_ node: ArchiveNode, store: LibraryStore) {
        if node.isDirectory {
            enter(node.path)
            return
        }
        Task {
            do {
                let url = try await cachedURL(for: node)
                NSWorkspace.shared.open(url)
            } catch {
                store.alertMessage = Self.message(for: error)
            }
        }
    }

    /// 拖出去：小文件当场解压（一瞬间）；大文件先登记，放下时再解压。
    func dragProvider(for node: ArchiveNode) -> NSItemProvider {
        let target = cacheDir.appendingPathComponent(node.path)
        if FileManager.default.fileExists(atPath: target.path), let provider = NSItemProvider(contentsOf: target) {
            return provider
        }
        let (archive, snapshot, cache, path) = (self.url, self.tree, self.cacheDir, node.path)
        let small = !node.isDirectory && (node.size ?? .max) <= 32 * 1024 * 1024
        if small, let url = try? Self.extractToCache(archive: archive, tree: snapshot, path: path, cacheDir: cache),
           let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        let type = node.isDirectory ? UTType.folder : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try Self.extractToCache(archive: archive, tree: snapshot, path: path, cacheDir: cache)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    // MARK: 解压到文件夹

    /// 「全部解压」：放在压缩包旁边。只有一个顶层项目就直接放它，否则装进和压缩包同名的文件夹（同名自动加 2）。
    func extractAll(store: LibraryStore) {
        guard !tree.entries.isEmpty else { return }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            extractChoosingFolder(paths: [""], store: store)
            return
        }
        if let single = tree.singleTopLevel {
            extract(paths: [single], all: true, to: parent, folderName: nil, store: store)
        } else {
            extract(paths: tree.children(of: "").map(\.path), all: true, to: parent, folderName: Self.stem(of: name), store: store)
        }
    }

    /// 「解压到…」：选一个文件夹。paths 为 [""] 表示全部。
    func extractChoosingFolder(paths: [String], store: LibraryStore) {
        guard let folder = ShelfActions.chooseFolder(prompt: String(localized: "解压到这里")) else { return }
        if paths == [""] {
            if let single = tree.singleTopLevel {
                extract(paths: [single], all: true, to: folder, folderName: nil, store: store)
            } else {
                extract(paths: tree.children(of: "").map(\.path), all: true, to: folder, folderName: Self.stem(of: name), store: store)
            }
        } else {
            extract(paths: paths, all: false, to: folder, folderName: nil, store: store)
        }
    }

    /// 「素材包.tar.gz」→「素材包」。
    static func stem(of name: String) -> String {
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return (name as NSString).deletingPathExtension
    }

    private func extract(paths: [String], all: Bool, to destination: URL, folderName: String?, store: LibraryStore) {
        guard busyMessage == nil else {
            store.showToast(String(localized: "正在解压，请稍等"))
            return
        }
        busyMessage = String(localized: "正在解压…")
        let (archive, snapshot) = (self.url, self.tree)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
                let fm = FileManager.default
                var target = destination
                do {
                    if let folderName {
                        let unique = ArchivePlacement.uniqueName(folderName) { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
                        target = destination.appendingPathComponent(unique, isDirectory: true)
                        try fm.createDirectory(at: target, withIntermediateDirectories: false)
                    }
                    // 先解在目标文件夹里的一个隐藏临时文件夹（同一块盘，移出来不用再拷一遍），再一个个移出来。
                    let staging = destination.appendingPathComponent(".shiduo-extract-\(UUID().uuidString)", isDirectory: true)
                    defer { try? fm.removeItem(at: staging) }
                    try ArchiveIO.extract(archive, entries: snapshot.entries(under: all ? [""] : paths), all: all, into: staging)
                    let placed = try ArchivePlacement.place(paths, from: staging, to: target)
                    if folderName != nil { return .success([target]) }
                    return .success(placed)
                } catch {
                    if folderName != nil, target != destination,
                       (try? fm.contentsOfDirectory(atPath: target.path))?.isEmpty == true {
                        try? fm.removeItem(at: target)
                    }
                    return .failure(error)
                }
            }.value
            busyMessage = nil
            switch result {
            case .success(let placed):
                store.filesWritten(placed)
                let folder = FileManager.default.displayName(atPath: destination.path)
                if placed.count == 1, let first = placed.first {
                    store.showToast(String(localized: "已解压到「\(folder)」：\(first.lastPathComponent)"))
                } else {
                    store.showToast(String(localized: "已解压 \(placed.count) 项到「\(folder)」"))
                }
            case .failure(let error):
                store.alertMessage = Self.message(for: error)
            }
        }
    }
}

// MARK: - 主窗口里打开 / 关闭

extension LibraryStore {
    /// 在拾掇里浏览压缩包（Pro；没解锁时弹出升级面板）。
    func browseArchive(_ url: URL) {
        guard license.isPro else {
            NSApp.activate(ignoringOtherApps: true)
            license.showPaywall = true
            return
        }
        guard ArchiveKind.isBrowsable(name: url.lastPathComponent) else { return }
        let session = ArchiveSession(url: url)
        archiveSession = session
        session.load()
    }

    func closeArchive() {
        archiveSession = nil
    }

    /// ⌘[ / ⌘↑ 在压缩包里时：先回上一层，已经在最外层就关掉压缩包。返回 true 表示处理了。
    func archiveGoUp() -> Bool {
        guard let session = archiveSession else { return false }
        if !session.goUp() { closeArchive() }
        return true
    }
}

// MARK: - 界面

/// 压缩包里一项的图标（按扩展名缓存一份系统图标）。
enum ArchiveIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: ArchiveNode) -> NSImage {
        let key = node.isDirectory ? "/folder" : (node.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

struct ArchiveBrowserView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var session: ArchiveSession
    @State private var previewURL: URL?
    @FocusState private var listFocused: Bool

    private static let sizeWidth: CGFloat = 90
    private static let dateWidth: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            banner
                .padding(.horizontal, 16)
                .padding(.top, 12)
            breadcrumb
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footnote
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .nativeQuickLook($previewURL, in: previewURL.map { [$0] } ?? [])
        .onChange(of: session.currentPath) { previewURL = nil }
    }

    // MARK: 顶部横条

    private var banner: some View {
        HStack(spacing: 10) {
            Text(verbatim: session.badge)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.purple.opacity(0.8)))
            Text(summary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProBadge()
            if let busy = session.busyMessage {
                ProgressView().controlSize(.small)
                Text(busy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("全部解压") { session.extractAll(store: store) }
                .buttonStyle(.borderedProminent)
                .disabled(session.tree.entries.isEmpty || session.busyMessage != nil)
                .help("解压到压缩包旁边")
            Button("解压所选…") { session.extractChoosingFolder(paths: session.selectedNodes.map(\.path), store: store) }
                .disabled(session.selection.isEmpty || session.busyMessage != nil)
            Button {
                store.closeArchive()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭压缩包")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(tint: .purple, radius: 14)
    }

    private var summary: String {
        if session.isLoading { return String(localized: "正在读取压缩包…") }
        let size = ByteCountFormatter.string(fromByteCount: session.tree.totalSize, countStyle: .file)
        let count = session.tree.fileCount
        if session.tree.hasUnknownSizes {
            return String(localized: "正在浏览压缩包 · 只读 · \(count) 个文件")
        }
        return String(localized: "正在浏览压缩包 · 只读 · \(count) 个文件 · 解压后 \(size)")
    }

    // MARK: 面包屑

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                session.enter("")
            } label: {
                Label(session.name, systemImage: "doc.zipper")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .fontWeight(session.currentPath.isEmpty ? .semibold : .regular)
            ForEach(ArchivePathLogic.breadcrumb(session.currentPath), id: \.path) { part in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(part.name) { session.enter(part.path) }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .fontWeight(part.path == session.currentPath ? .semibold : .regular)
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.primary)
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if session.isLoading {
            ProgressView("正在读取压缩包…")
        } else if let error = session.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Button("返回") { store.closeArchive() }
            }
            .padding(30)
        } else {
            VStack(spacing: 0) {
                header
                List(selection: $session.selection) {
                    ForEach(session.nodes) { node in
                        row(node)
                            .contentShape(Rectangle())
                            // 右键菜单快照（macOS 15+ 不走列表自己的 SwiftUI 菜单，见 StableContextMenu.swift）：
                            // 右键的这一项在选中里 → 作用在全部选中，否则只作用在这一项。
                            .stableContextMenu {
                                menu(for: session.selection.contains(node.id) ? session.selection : [node.id])
                            }
                            .tag(node.id)
                            .onDrag { session.dragProvider(for: node) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                // 空白处右键：「全部解压到…」。
                .stableTableBackgroundContextMenu { menu(for: []) }
                .contextMenu(forSelectionType: String.self) { ids in
                    if #available(macOS 15.0, *) {
                        EmptyView()
                    } else {
                        menu(for: ids)
                    }
                } primaryAction: { ids in
                    guard ids.count == 1, let id = ids.first, let node = session.nodes.first(where: { $0.id == id }) else { return }
                    session.open(node, store: store)
                }
                .onKeyPress(.space) {
                    quickLook()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard previewURL != nil else { return .ignored }
                    previewURL = nil
                    return .handled
                }
                .onAppear { listFocused = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: Self.sizeWidth, alignment: .trailing)
            Text("压缩后").frame(width: Self.sizeWidth, alignment: .trailing)
            Text("修改日期").frame(width: Self.dateWidth, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 26)
        .padding(.vertical, 6)
    }

    private func row(_ node: ArchiveNode) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: ArchiveIcons.icon(for: node))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("加了密码")
                }
                if node.isDirectory {
                    Text("\(node.fileCount) 项")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText(node.size))
                .frame(width: Self.sizeWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(sizeText(node.compressedSize))
                .frame(width: Self.sizeWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
            Group {
                if let date = node.modified {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text(verbatim: "--")
                }
            }
            .frame(width: Self.dateWidth, alignment: .leading)
            .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.vertical, 2)
    }

    private func sizeText(_ size: Int64?) -> String {
        guard let size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let picked = session.nodes.filter { ids.contains($0.id) }
        if picked.count == 1, let node = picked.first {
            Button(node.isDirectory ? String(localized: "打开") : String(localized: "用默认 App 打开")) {
                session.open(node, store: store)
            }
            if !node.isDirectory {
                Button("快速查看") {
                    session.selection = [node.id]
                    quickLook()
                }
            }
            Divider()
        }
        if !picked.isEmpty {
            Button(picked.count > 1 ? String(localized: "解压 \(picked.count) 项到…") : String(localized: "解压到…")) {
                session.extractChoosingFolder(paths: picked.map(\.path), store: store)
            }
        }
        Button("全部解压到…") { session.extractChoosingFolder(paths: [""], store: store) }
        if picked.count == 1, let node = picked.first {
            Divider()
            Button("拷贝名称") { FileActions.copy(node.name) }
        }
    }

    // MARK: 底部说明

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("支持 zip、tar、tar.gz（7z、rar 系统能读的也行）。空格快速查看、双击打开、拖出来就解压到放下的位置，压缩包本身不动。")
                .font(.callout)
            Text("加了密码的压缩包暂时打不开；预览和打开用的文件放在系统临时文件夹里，一天后自动清掉。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(radius: 14)
    }

    /// 空格：解压到临时文件夹后用系统的快速查看；再按一次关掉。
    private func quickLook() {
        if previewURL != nil {
            previewURL = nil
            return
        }
        guard let node = session.selectedNodes.first(where: { !$0.isDirectory }) else { return }
        Task {
            do {
                previewURL = try await session.cachedURL(for: node)
            } catch {
                store.alertMessage = ArchiveSession.message(for: error)
            }
        }
    }
}
