import AppKit
import SwiftUI

/// 文件夹占用图：方块越大，占的空间越多。点文件夹往里看，点面包屑返回。
struct StorageNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64
    var done: Bool
    var id: String { url.path }
}

@MainActor
final class StorageMapModel: ObservableObject {
    @Published var root: URL = Demo.isOn ? Demo.folder : FileManager.default.homeDirectoryForCurrentUser
    @Published var path: [URL] = []
    @Published var nodes: [StorageNode] = []
    @Published var isScanning = false

    private var cache: [String: Int64] = [:]
    private var task: Task<Void, Never>?

    var current: URL { path.last ?? root }
    var total: Int64 { nodes.reduce(0) { $0 + $1.size } }

    func setRoot(_ url: URL) {
        root = url
        path = []
        load()
    }

    func enter(_ url: URL) {
        path.append(url)
        load()
    }

    func jump(to index: Int) {
        // index -1 表示根目录。
        path = index < 0 ? [] : Array(path.prefix(index + 1))
        load()
    }

    func rescan() {
        cache = cache.filter { !$0.key.hasPrefix(current.path) }
        load()
    }

    func removed(_ paths: Set<String>) {
        nodes.removeAll { paths.contains($0.url.path) }
        cache = cache.filter { key, _ in !paths.contains { key.hasPrefix($0) } }
    }

    func load() {
        task?.cancel()
        let folder = current
        let isHome = folder.path == NSHomeDirectory()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        var list: [StorageNode] = []
        for url in children {
            if isHome && url.lastPathComponent == "Library" { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            if Demo.isOn, let fake = Demo.fakeSize(url) {
                list.append(StorageNode(url: url, name: url.lastPathComponent, isDirectory: v?.isDirectory == true, size: fake, done: true))
                continue
            }
            let isDir = v?.isDirectory == true
            if isDir {
                let cached = cache[url.path]
                list.append(StorageNode(url: url, name: url.lastPathComponent, isDirectory: !(v?.isPackage ?? false), size: cached ?? 0, done: cached != nil))
            } else {
                let size = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                list.append(StorageNode(url: url, name: url.lastPathComponent, isDirectory: false, size: size, done: true))
            }
        }
        nodes = list.sorted { $0.size > $1.size }
        let pending = list.filter { !$0.done }.map(\.url)
        guard !pending.isEmpty else {
            isScanning = false
            return
        }
        isScanning = true
        task = Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                var next = 0
                while next < min(4, pending.count) {
                    let url = pending[next]
                    group.addTask(priority: .utility) { (url.path, FileActions.directorySize(url)) }
                    next += 1
                }
                for await (path, size) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    cache[path] = size
                    if let i = nodes.firstIndex(where: { $0.url.path == path }) {
                        nodes[i].size = size
                        nodes[i].done = true
                    }
                    nodes.sort { $0.size > $1.size }
                    if next < pending.count {
                        let url = pending[next]
                        group.addTask(priority: .utility) { (url.path, FileActions.directorySize(url)) }
                        next += 1
                    }
                }
            }
            if !Task.isCancelled { isScanning = false }
        }
    }
}

/// 平铺方块布局（squarified treemap）。
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var index = 0
        while index < areas.count {
            let short = Double(min(remaining.width, remaining.height))
            var row: [Int] = [index]
            var rowSum = areas[index]
            func worst(_ sum: Double, _ items: [Int]) -> Double {
                let maxA = items.map { areas[$0] }.max() ?? 0
                let minA = items.map { areas[$0] }.min() ?? 0
                guard sum > 0, minA > 0 else { return .infinity }
                let s2 = short * short
                return max(s2 * maxA / (sum * sum), (sum * sum) / (s2 * minA))
            }
            var next = index + 1
            while next < areas.count {
                let candidate = row + [next]
                if worst(rowSum + areas[next], candidate) <= worst(rowSum, row) {
                    row = candidate
                    rowSum += areas[next]
                    next += 1
                } else { break }
            }
            let horizontal = remaining.width >= remaining.height
            let thickness = CGFloat(rowSum / short)
            var offset: CGFloat = 0
            for i in row {
                let length = CGFloat(areas[i] / Double(thickness))
                if horizontal {
                    result[i] = CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                } else {
                    result[i] = CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                }
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            index = next
        }
        return result
    }
}

struct StorageMapView: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var model = StorageMapModel()
    @State private var hovered: String?

    private let palette: [Color] = [
        Color(red: 0.36, green: 0.62, blue: 0.98), Color(red: 0.98, green: 0.60, blue: 0.25),
        Color(red: 0.35, green: 0.78, blue: 0.48), Color(red: 0.93, green: 0.40, blue: 0.55),
        Color(red: 0.62, green: 0.50, blue: 0.95), Color(red: 0.20, green: 0.74, blue: 0.78),
        Color(red: 0.95, green: 0.78, blue: 0.25), Color(red: 0.55, green: 0.60, blue: 0.70),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            FullDiskAccessNote()
            Divider()
            GeometryReader { geo in
                let shown = Array(model.nodes.filter { $0.size > 0 }.prefix(80))
                let rects = Treemap.layout(shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 12, dy: 12))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                        tile(node, color: palette[index % palette.count], rect: rects[index])
                    }
                }
            }
            .overlay {
                if model.nodes.isEmpty {
                    ContentUnavailableView("这个文件夹是空的", systemImage: "folder")
                }
            }
        }
        .navigationTitle("空间占用图")
        .navigationSubtitle("\(model.current.lastPathComponent) · \(model.total.byteText)")
        .onAppear { if model.nodes.isEmpty { model.load() } }
        .onChange(of: store.filesChangedTick) { model.rescan() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                Button("个人文件夹") { model.setRoot(FileManager.default.homeDirectoryForCurrentUser) }
                Button("下载") { model.setRoot(URL(fileURLWithPath: Folders.downloads)) }
                Button("文稿") { model.setRoot(URL(fileURLWithPath: Folders.documents)) }
                Button("桌面") { model.setRoot(URL(fileURLWithPath: Folders.desktop)) }
                Button("应用程序") { model.setRoot(URL(fileURLWithPath: "/Applications")) }
                Divider()
                Button("选择文件夹…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { model.setRoot(url) }
                }
            } label: {
                Label(FileManager.default.displayName(atPath: model.root.path), systemImage: "externaldrive")
            }
            .fixedSize()
            ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                Button(url.lastPathComponent) { model.jump(to: index) }
                    .buttonStyle(.link)
                    .lineLimit(1)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("正在计算大小…").font(.caption).foregroundStyle(.secondary)
            }
            if !model.path.isEmpty {
                Button {
                    model.jump(to: model.path.count - 2)
                } label: {
                    Label("返回上一层", systemImage: "chevron.left")
                }
            }
            Button {
                model.rescan()
            } label: {
                Label("重新计算", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func tile(_ node: StorageNode, color: Color, rect: CGRect) -> some View {
        let big = rect.width > 70 && rect.height > 40
        let isHovered = hovered == node.id
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(isHovered ? 0.95 : 0.75), color.opacity(isHovered ? 0.8 : 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if big {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                            Text(node.name).lineLimit(1)
                        }
                        .font(.system(size: rect.width > 160 ? 13 : 11, weight: .semibold))
                        Text(node.done ? node.size.byteText : String(localized: "计算中…"))
                            .font(.system(size: rect.width > 160 ? 12 : 10))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(8)
                }
            }
            .frame(width: max(rect.width - 3, 1), height: max(rect.height - 3, 1))
            .offset(x: rect.minX, y: rect.minY)
            .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
            .help("\(node.name)\n" + (node.done ? node.size.byteText : String(localized: "计算中…")))
            .onTapGesture(count: 2) {
                if !node.isDirectory { NSWorkspace.shared.open(node.url) }
            }
            .onTapGesture {
                if node.isDirectory { model.enter(node.url) }
            }
            .stableContextMenu {
                if node.isDirectory { Button("打开这个文件夹的占用图") { model.enter(node.url) } }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                Button("拷贝路径") { FileActions.copy(node.url.path) }
                Divider()
                Button("大文件搬家…") {
                    if let item = FileItem(url: node.url) {
                        var copy = item
                        copy.size = node.size
                        store.requestMoveOut([copy])
                    }
                }
                // 和其他地方一样不弹确认：小提示上可以撤销（⌘Z 也行）。只有 5 GB 以上的大块才先问一句。
                Button("移到废纸篓", role: .destructive) {
                    guard let item = FileItem(url: node.url) else { return }
                    var copy = item
                    copy.size = node.size
                    if TrashConfirm.needsConfirm(count: 1, bytes: node.size) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "将“\(copy.name)”移到废纸篓？")
                        alert.informativeText = String(localized: "它占了 \(node.size.byteText)。随时可以从废纸篓里恢复。")
                        alert.addButton(withTitle: String(localized: "移到废纸篓"))
                        alert.addButton(withTitle: String(localized: "取消"))
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    store.moveToTrash([copy]) { moved in model.removed(moved) }
                }
            }
            .animation(.easeOut(duration: 0.2), value: rect)
    }
}
