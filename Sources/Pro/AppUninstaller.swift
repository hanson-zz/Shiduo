import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 卸载 App 连残留一起清（Pro）

/// 找出 App 在个人资源库里留下的文件，和 App 一起移到废纸篓。
/// 只移到废纸篓、记进「清理记录」，30 天内可以放回原处；从不直接删除。
@MainActor
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()

    /// 正在卸载的 App（不为 nil 时主窗口弹出卸载面板）。
    @Published var target: URL?

    /// 打开卸载面板。不是 Pro 就弹付费页。
    func open(_ app: URL) {
        LicenseManager.shared.startTrialIfNeeded()
        guard LicenseManager.shared.isPro else {
            LicenseManager.shared.showPaywall = true
            return
        }
        MediaTools.bringMainWindow()
        target = app
    }

    /// 让用户在「应用程序」里挑一个 App。
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选一个要卸载的 App，拾掇会一起找出它留在资源库里的文件。")
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    struct AppInfo {
        var url: URL
        var name: String
        var bundleID: String?
        var size: Int64
        var problem: String?
    }

    nonisolated static func info(for app: URL) -> AppInfo {
        let bundle = Bundle(url: app)
        let id = bundle?.bundleIdentifier
        let display = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let problem = UninstallLogic.problem(appPath: app.path, bundleID: id, selfBundleID: Bundle.main.bundleIdentifier)
        return AppInfo(url: app, name: display, bundleID: id, size: FileActions.directorySize(app), problem: problem)
    }

    /// 扫描残留（在后台线程调用）。
    nonisolated static func leftovers(bundleID: String, appName: String, fileName: String,
                                      home: String = NSHomeDirectory()) -> [AppLeftover] {
        let fm = FileManager.default
        var found: [AppLeftover] = []
        var names = [appName]
        if fileName != appName { names.append(fileName) }
        for name in names {
            for (path, kind) in UninstallLogic.directCandidates(bundleID: bundleID, appName: name, home: home)
            where fm.fileExists(atPath: path) {
                found.append(AppLeftover(path: path, kind: kind))
            }
        }
        let lib = (home as NSString).appendingPathComponent("Library")
        for (folder, kind) in UninstallLogic.scanFolders() {
            let dir = (lib as NSString).appendingPathComponent(folder)
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where UninstallLogic.nameBelongs(entry, bundleID: bundleID) {
                found.append(AppLeftover(path: (dir as NSString).appendingPathComponent(entry), kind: kind))
            }
        }
        var result = UninstallLogic.dedupe(found).filter { UninstallLogic.isSafeLeftover($0.path, home: home) }
        for index in result.indices {
            let url = URL(fileURLWithPath: result[index].path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                result[index].size = FileActions.directorySize(url)
            } else {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                result[index].size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }
        return result
    }

    /// 把 App 和选中的残留移到废纸篓，记进清理记录。返回给用户看的结果。
    func uninstall(app: AppInfo, leftovers: [AppLeftover]) -> String {
        var urls = [app.url]
        urls += leftovers.map { URL(fileURLWithPath: $0.path) }
        let outcome = FileActions.trash(urls)
        let moved = Set(outcome.moved.map(\.path))
        var entries: [(name: String, original: String, trashed: String?, size: Int64)] = []
        if moved.contains(app.url.path) {
            entries.append((name: app.url.lastPathComponent, original: app.url.path, trashed: outcome.trashed[app.url.path], size: app.size))
        }
        for item in leftovers where moved.contains(item.path) {
            entries.append((name: item.name, original: item.path, trashed: outcome.trashed[item.path], size: item.size))
        }
        if !entries.isEmpty {
            let batch = CleanupHistory.shared.recordTrash(entries)
            if let store = LibraryStore.shared {
                store.filesChangedTick += 1
                store.showUndoToast(String(localized: "已卸载 \(app.name) · 30 天内可在「清理记录」里恢复"), batch: batch)
            }
        }
        if !moved.contains(app.url.path) {
            return String(localized: "没能把 \(app.name) 移到废纸篓（可能需要管理员权限，或它正在运行）。")
        }
        let failed = outcome.failed.count + outcome.skipped.count
        if failed > 0 {
            return String(localized: "已卸载 \(app.name)，有 \(failed) 个残留没能移走。")
        }
        return ""
    }
}

// MARK: - 卸载面板

struct UninstallSheet: View {
    let app: URL
    @Environment(\.dismiss) private var dismiss
    @State private var info: AppUninstaller.AppInfo?
    @State private var items: [AppLeftover] = []
    @State private var selected: Set<String> = []
    @State private var scanning = true
    @State private var running = false
    @State private var resultText: String?

    private var selectedBytes: Int64 {
        (info?.size ?? 0) + items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("卸载 \(info?.name ?? app.deletingPathExtension().lastPathComponent)")
                            .font(.title2.weight(.semibold))
                        ProBadge()
                    }
                    Text("App 和勾选的残留都只会移到废纸篓，30 天内可以在「清理记录」里放回。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let problem = info?.problem {
                Label(problem, systemImage: "hand.raised")
                    .foregroundStyle(.orange)
            } else if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在资源库里找残留…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                list
            }

            if let resultText {
                Label(resultText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                if info?.problem == nil, !scanning {
                    Text("共 \(selectedBytes.byteText)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(resultText == nil ? String(localized: "取消") : String(localized: "完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if resultText == nil, info?.problem == nil {
                    Button("移到废纸篓", role: .destructive) { perform() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(scanning || running || info == nil)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await load() }
    }

    private var isRunning: Bool {
        guard let id = info?.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isRunning {
                HStack {
                    Label("\(info?.name ?? "") 正在运行，先退出它再卸载更干净。", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("退出 App") {
                        if let id = info?.bundleID {
                            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
                        }
                    }
                }
                .font(.callout)
            }
            HStack {
                Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                Text(info?.url.lastPathComponent ?? app.lastPathComponent)
                Spacer()
                Text((info?.size ?? 0).byteText).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            Divider()
            if items.isEmpty {
                Text("资源库里没找到它的残留，只会移走 App 本身。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("找到 \(items.count) 处残留")
                        .font(.headline)
                    Spacer()
                    Button(selected.count == items.count ? String(localized: "全不选") : String(localized: "全选")) {
                        selected = selected.count == items.count ? [] : Set(items.map(\.id))
                    }
                    .buttonStyle(.link)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            Toggle(isOn: Binding(
                                get: { selected.contains(item.id) },
                                set: { on in
                                    if on { selected.insert(item.id) } else { selected.remove(item.id) }
                                }
                            )) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).lineLimit(1).truncationMode(.middle)
                                        Text("\(item.kind.title) · \((item.path as NSString).abbreviatingWithTildeInPath)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .help(item.path)
                                    Spacer()
                                    Text(item.size.byteText)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func load() async {
        let url = app
        let loaded = await Task.detached(priority: .userInitiated) { AppUninstaller.info(for: url) }.value
        info = loaded
        guard loaded.problem == nil, let id = loaded.bundleID else {
            scanning = false
            return
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        let found = await Task.detached(priority: .userInitiated) {
            AppUninstaller.leftovers(bundleID: id, appName: loaded.name, fileName: fileName)
        }.value
        items = found
        selected = Set(found.map(\.id))
        scanning = false
    }

    private func perform() {
        guard let info else { return }
        running = true
        let chosen = items.filter { selected.contains($0.id) }
        let text = AppUninstaller.shared.uninstall(app: info, leftovers: chosen)
        running = false
        if text.isEmpty {
            dismiss()
        } else {
            resultText = text
        }
    }
}

// MARK: - 清理页上的入口

struct AppUninstallRow: View {
    @EnvironmentObject private var license: LicenseManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.app")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("卸载 App，连残留一起清")
                        .font(.headline)
                    ProBadge()
                        .opacity(license.isPro ? 0.55 : 1)
                }
                Text("把 App 拖进废纸篓，偏好设置、缓存和应用数据还留在资源库里。拾掇一起列出来，你勾选后只移到废纸篓。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("选择 App…") { AppUninstaller.shared.chooseApp() }
        }
        .padding(14)
        .glassCard(radius: 16)
    }
}
