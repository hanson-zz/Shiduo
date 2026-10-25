import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 卸载 App 连残留一起清（Pro）

/// 找出 App 在个人资源库里留下的文件，和 App 一起移到废纸篓。
/// 只移到废纸篓、记进「清理记录」，30 天内可以放回原处；从不直接删除。
@MainActor
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()

    static let windowID = "uninstall"

    /// 打开卸载窗口（只有一个，从哪个窗口、暂存架发起都一样；主窗口关着也能打开）。不是 Pro 就弹付费页。
    func open(_ app: URL) {
        guard MediaTools.requirePro() else { return }
        ToolWindow.show(Self.windowID, title: String(localized: "卸载 App")) {
            UninstallSheet(app: app) { ToolWindow.close(Self.windowID) }
                .id(app)
        }
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
    nonisolated static func leftovers(bundleID: String, appName: String, fileName: String, appPath: String,
                                      home: String = NSHomeDirectory()) -> [AppLeftover] {
        let fm = FileManager.default
        var found: [AppLeftover] = []
        var names = [appName]
        if fileName != appName { names.append(fileName) }
        for name in names {
            for (path, kind, confidence) in UninstallLogic.directCandidates(bundleID: bundleID, appName: name, home: home)
            where fm.fileExists(atPath: path) {
                found.append(AppLeftover(path: path, kind: kind, confidence: confidence))
            }
        }
        let lib = (home as NSString).appendingPathComponent("Library")
        for (folder, kind) in UninstallLogic.scanFolders() {
            let dir = (lib as NSString).appendingPathComponent(folder)
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                guard let confidence = UninstallLogic.match(entry, bundleID: bundleID) else { continue }
                var item = AppLeftover(path: (dir as NSString).appendingPathComponent(entry), kind: kind, confidence: confidence)
                if confidence == .prefix {
                    // 「com.google.Chrome.canary」这类兄弟 App 还装着：它的数据不算这个 App 的残留。
                    item.owner = UninstallLogic.otherOwner(entry, bundleID: bundleID, appPath: appPath) { id in
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
                    }
                    if item.owner != nil { continue }
                }
                found.append(item)
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

    /// 同一个 bundleID 的其他副本（不含它自己）。
    nonisolated static func otherCopies(of app: URL, bundleID: String) -> [String] {
        let all = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
        return UninstallLogic.otherCopies(appPath: app.path, all: all, home: NSHomeDirectory())
    }

    /// 正在运行的「这一份」App（别的副本在运行不算）。
    static func runningInstances(of app: URL, bundleID: String?) -> [NSRunningApplication] {
        guard let bundleID else { return [] }
        let me = app.standardizedFileURL.resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { running in
            guard let url = running.bundleURL else { return true }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == me
        }
    }

    /// 先把 App 本体移到废纸篓；只有它真的移走了，才移选中的残留（App 移不走时残留一个不动）。
    /// 移动在后台线程做（残留可能很多、很大），和其他地方一样：FileManager.trashItem（访达里能「放回原处」）、
    /// 记进清理记录、⌘Z 撤销、移到废纸篓的音效。返回给用户看的结果（空字符串表示全部成功）。
    func uninstall(app: AppInfo, leftovers: [AppLeftover]) async -> String {
        let appURL = app.url
        let leftoverPaths = leftovers.map(\.path)
        let agents = leftovers.filter { $0.kind == .launchAgents && $0.path.hasSuffix(".plist") }.map(\.path)
        let work = await Task.detached(priority: .userInitiated) { () -> (app: (moved: [URL], failed: [URL], skipped: [URL], trashed: [String: String]), rest: (moved: [URL], failed: [URL], skipped: [URL], trashed: [String: String])?) in
            let first = FileActions.trash([appURL])
            guard first.moved.contains(appURL) else { return (first, nil) }
            // 开机启动项先从 launchd 卸下来，不然 plist 进了废纸篓它还在跑，直到注销。
            for plist in agents { Self.bootout(plist) }
            return (first, FileActions.trash(leftoverPaths.map { URL(fileURLWithPath: $0) }))
        }.value
        guard let outcome = work.rest else {
            return String(localized: "没能把 \(app.name) 移到废纸篓（可能需要管理员权限，或它正在运行），资源库里的数据一个没动。")
        }
        var entries: [(name: String, original: String, trashed: String?, size: Int64)] = [
            (name: app.url.lastPathComponent, original: app.url.path, trashed: work.app.trashed[app.url.path], size: app.size),
        ]
        let moved = Set(outcome.moved.map(\.path))
        for item in leftovers where moved.contains(item.path) {
            entries.append((name: item.name, original: item.path, trashed: outcome.trashed[item.path], size: item.size))
        }
        TrashSound.play()
        let batch = CleanupHistory.shared.recordTrash(entries)
        if let store = LibraryStore.shared {
            store.forget(paths: moved.union([app.url.path]))
            store.filesChangedTick += 1
            // 小提示上的「撤销」和 ⌘Z 走同一个撤销栈。
            FileUndoCenter.shared.registerHistory(batch: batch, name: String(localized: "卸载 App"),
                                                  toast: String(localized: "已卸载 \(app.name) · 30 天内可在「清理记录」里恢复"))
        }
        let failed = outcome.failed.count + outcome.skipped.count
        if failed > 0 {
            return String(localized: "已卸载 \(app.name)，有 \(failed) 个残留没能移走。")
        }
        return ""
    }

    /// launchctl bootout gui/<uid> <plist>：失败（本来就没加载）也没关系。
    nonisolated private static func bootout(_ plist: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", plist]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}

// MARK: - 卸载面板

struct UninstallSheet: View {
    let app: URL
    let close: () -> Void
    @State private var info: AppUninstaller.AppInfo?
    @State private var items: [AppLeftover] = []
    @State private var selected: Set<String> = []
    @State private var scanning = true
    @State private var working = false
    @State private var resultText: String?
    /// 这一份 App 正在运行（收到系统的启动 / 退出通知时刷新）。
    @State private var appRunning = false
    /// 正在等它退出（「退出并卸载」）。
    @State private var quitting = false
    /// 等了很久还没退出：给「强制退出」。
    @State private var quitTimedOut = false
    /// 同一个 App 的其他副本：资源库数据是共用的。
    @State private var otherCopies: [String] = []
    @State private var confirmLarge = false

    private var selectedItems: [AppLeftover] { items.filter { selected.contains($0.id) } }

    private var selectedBytes: Int64 {
        (info?.size ?? 0) + selectedItems.reduce(0) { $0 + $1.size }
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
                    Text("先移走 App，成功后才移走勾选的残留。都只是移到废纸篓，30 天内可以在「清理记录」里放回。")
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if info?.problem == nil, !scanning {
                    Text("共 \(selectedBytes.byteText)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(resultText == nil ? String(localized: "取消") : String(localized: "完成")) { close() }
                    .keyboardShortcut(.cancelAction)
                if resultText == nil, info?.problem == nil {
                    if appRunning {
                        Button(quitting ? String(localized: "正在等它退出…") : String(localized: "退出并卸载"), role: .destructive) {
                            Task { await quitThenUninstall(force: false) }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(scanning || working || quitting || info == nil)
                    } else {
                        Button("移到废纸篓", role: .destructive) { requestPerform() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(scanning || working || quitting || info == nil)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunning()
        }
        .confirmationDialog(
            String(localized: "有 \(AppLeftover.largeCount(selectedItems)) 项超过 1 GB"),
            isPresented: $confirmLarge,
            titleVisibility: .visible
        ) {
            Button("仍然移到废纸篓", role: .destructive) { perform() }
            Button("再看看", role: .cancel) {}
        } message: {
            Text(UninstallLogic.largeItems(selectedItems).map(\.name).joined(separator: "、"))
        }
    }

    private func refreshRunning() {
        appRunning = !AppUninstaller.runningInstances(of: app, bundleID: info?.bundleID).isEmpty
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appRunning {
                HStack {
                    Label(quitTimedOut ? String(localized: "\(info?.name ?? "") 还没退出，可能有未保存的内容。")
                                       : String(localized: "\(info?.name ?? "") 正在运行，要先退出才能卸载。"),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Spacer()
                    if quitTimedOut {
                        Button("强制退出") { Task { await quitThenUninstall(force: true) } }
                    } else {
                        Button("只退出 App") { quit(force: false) }
                            .disabled(quitting)
                    }
                }
                .font(.callout)
            }
            if !otherCopies.isEmpty {
                Label(String(localized: "另一份副本在 \((otherCopies[0] as NSString).abbreviatingWithTildeInPath)，资源库里的数据是它们共用的。残留默认不勾选，只卸载这一份 App。"),
                      systemImage: "square.on.square")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                            row(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func row(_ item: AppLeftover) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(item.id) },
            set: { on in
                if on { selected.insert(item.id) } else { selected.remove(item.id) }
            }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        if let note = note(for: item) {
                            Text(note)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                    }
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
                    .foregroundStyle(item.size >= UninstallLogic.largeBytes ? Color.orange : Color.secondary)
                    .monospacedDigit()
            }
        }
        .toggleStyle(.checkbox)
    }

    /// 残留旁边的小标签：说明为什么没默认勾选。
    private func note(for item: AppLeftover) -> String? {
        switch item.confidence {
        case .name: return String(localized: "按名字匹配，请确认")
        case .prefix: return String(localized: "可能是它的辅助程序，请确认")
        case .exact:
            if item.kind == .groupContainers { return String(localized: "多个 App 共用，请确认") }
            if item.size >= UninstallLogic.largeBytes { return String(localized: "很大，请确认") }
            return nil
        }
    }

    private func load() async {
        let url = app
        let loaded = await Task.detached(priority: .userInitiated) { AppUninstaller.info(for: url) }.value
        info = loaded
        refreshRunning()
        guard loaded.problem == nil, let id = loaded.bundleID else {
            scanning = false
            return
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        let (found, copies) = await Task.detached(priority: .userInitiated) {
            (AppUninstaller.leftovers(bundleID: id, appName: loaded.name, fileName: fileName, appPath: url.path,
                                      home: Demo.isOn ? Demo.uninstallHome.path : NSHomeDirectory()),
             AppUninstaller.otherCopies(of: url, bundleID: id))
        }.value
        items = found
        otherCopies = copies
        selected = Set(found.filter { UninstallLogic.selectedByDefault($0, hasOtherCopies: !copies.isEmpty) }.map(\.id))
        scanning = false
    }

    private func quit(force: Bool) {
        for running in AppUninstaller.runningInstances(of: app, bundleID: info?.bundleID) {
            if force { running.forceTerminate() } else { running.terminate() }
        }
    }

    /// 让它退出（terminate 是异步的），等它真的退出了再卸载；10 秒还没退出就提示可以强制退出。
    private func quitThenUninstall(force: Bool) async {
        quitting = true
        quitTimedOut = false
        quit(force: force)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            refreshRunning()
            if !appRunning { break }
        }
        quitting = false
        if appRunning {
            quitTimedOut = true
        } else {
            requestPerform()
        }
    }

    private func requestPerform() {
        refreshRunning()
        guard !appRunning else { return }
        if UninstallLogic.largeItems(selectedItems).isEmpty {
            perform()
        } else {
            confirmLarge = true
        }
    }

    private func perform() {
        guard let info, !working else { return }
        refreshRunning()
        guard !appRunning else { return }
        working = true
        let leftovers = selectedItems
        Task {
            let text = await AppUninstaller.shared.uninstall(app: info, leftovers: leftovers)
            working = false
            if text.isEmpty {
                close()
            } else {
                resultText = text
            }
        }
    }
}

extension AppLeftover {
    static func largeCount(_ items: [AppLeftover]) -> Int { UninstallLogic.largeItems(items).count }
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
