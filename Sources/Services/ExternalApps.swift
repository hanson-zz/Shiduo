import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「打开方式 ▸」「在终端打开」「在编辑器打开」（免费）。
@MainActor
enum ExternalApps {
    /// 设置 › 通用：在终端打开用哪个终端（Bundle ID；空 = 系统的「终端」）。
    static let terminalKey = "preferredTerminal"
    /// 设置 › 通用：在编辑器打开用哪个编辑器（Bundle ID；空 = 自动：装了的里面排最前的）。
    static let editorKey = "preferredEditor"

    // MARK: 认 App

    static func appURL(for tool: ExternalTool) -> URL? {
        for id in tool.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    static func installed(_ list: [ExternalTool]) -> [ExternalTool] {
        list.filter { appURL(for: $0) != nil }
    }

    private static func installedIDs(_ list: [ExternalTool]) -> Set<String> {
        Set(list.flatMap(\.bundleIDs).filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    static var terminal: ExternalTool? {
        ExternalToolCatalog.resolve(preferred: UserDefaults.standard.string(forKey: terminalKey),
                                    installed: installedIDs(ExternalToolCatalog.terminals), in: ExternalToolCatalog.terminals)
    }

    static var editor: ExternalTool? {
        ExternalToolCatalog.resolve(preferred: UserDefaults.standard.string(forKey: editorKey),
                                    installed: installedIDs(ExternalToolCatalog.editors), in: ExternalToolCatalog.editors)
    }

    // MARK: 在终端 / 编辑器打开

    /// 文件夹在终端里打开；文件打开它所在的文件夹。
    static func openInTerminal(_ entries: [(path: String, isDirectory: Bool)]) {
        guard let tool = terminal, let app = appURL(for: tool) else {
            LibraryStore.shared?.alertMessage = String(localized: "没有找到终端 App。")
            return
        }
        let folders = ExternalToolCatalog.terminalFolders(entries).prefix(10).map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !folders.isEmpty else { return }
        for folder in folders { open([folder], with: app, name: tool.name) }
    }

    static func openInTerminal(_ items: [FileItem]) {
        openInTerminal(items.map { ($0.path, $0.isDirectory) })
    }

    static func openInEditor(_ items: [FileItem]) {
        guard let tool = editor, let app = appURL(for: tool) else {
            LibraryStore.shared?.alertMessage = String(localized: "没有找到编辑器 App。")
            return
        }
        let entries = items.map { ($0.path, $0.isDirectory) }
        let targets = ExternalToolCatalog.editorTargets(entries, tool: tool)
        guard !targets.isEmpty else {
            LibraryStore.shared?.alertMessage = String(localized: "\(tool.name)打不开文件夹。可以在「设置 › 通用 › 在终端 / 编辑器中打开」里换一个编辑器。")
            return
        }
        open(targets.map { URL(fileURLWithPath: $0) }, with: app, name: tool.name)
    }

    static func openFolderInEditor(_ folder: URL) {
        guard let tool = editor, let app = appURL(for: tool) else { return }
        guard tool.opensFolders else {
            LibraryStore.shared?.alertMessage = String(localized: "\(tool.name)打不开文件夹。可以在「设置 › 通用 › 在终端 / 编辑器中打开」里换一个编辑器。")
            return
        }
        open([folder], with: app, name: tool.name)
    }

    static func open(_ urls: [URL], with app: URL, name: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                LibraryStore.shared?.alertMessage = String(localized: "用「\(name)」打开失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 打开方式

    /// 一个文件的默认 App 和能打开它的 App。
    static func apps(for urls: [URL]) -> (defaultApp: OpenWithLogic.App?, others: [OpenWithLogic.App]) {
        let list = Array(urls.prefix(50))
        guard !list.isEmpty else { return (nil, []) }
        let defaults = list.map { NSWorkspace.shared.urlForApplication(toOpen: $0).map(app(at:)) }
        let all = list.map { NSWorkspace.shared.urlsForApplications(toOpen: $0).map(app(at:)) }
        let defaultApp = OpenWithLogic.commonDefault(defaults)
        let common = OpenWithLogic.commonApps(all)
        return (defaultApp, Array(OpenWithLogic.others(common, excluding: defaultApp).prefix(40)))
    }

    private static func app(at url: URL) -> OpenWithLogic.App {
        let bundle = Bundle(url: url)
        return OpenWithLogic.App(path: url.path, bundleID: bundle?.bundleIdentifier,
                                 name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }

    private static var iconCache: [String: NSImage] = [:]

    /// 菜单里的 16×16 App 图标。
    static func icon(_ path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        iconCache[path] = image
        return image
    }

    /// 「其他…」：在「应用程序」里选一个 App。
    static func chooseOther(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "打开")
        panel.message = String(localized: "选择用来打开的 App")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(urls, with: app, name: FileManager.default.displayName(atPath: app.path))
    }
}

/// 右键菜单里的「打开方式 ▸」。
struct OpenWithMenu: View {
    let urls: [URL]

    var body: some View {
        // 查 App 的活放在子视图里：只有子菜单真的展开时才做。
        Menu("打开方式") { OpenWithMenuContent(urls: urls) }
    }
}

private struct OpenWithMenuContent: View {
    let urls: [URL]

    var body: some View {
        let apps = ExternalApps.apps(for: urls)
        if let app = apps.defaultApp {
            Button {
                open(app)
            } label: {
                Label {
                    Text(verbatim: app.name) + Text("（默认）")
                } icon: {
                    Image(nsImage: ExternalApps.icon(app.path))
                }
            }
            if !apps.others.isEmpty { Divider() }
        }
        ForEach(apps.others) { app in
            Button {
                open(app)
            } label: {
                Label {
                    Text(verbatim: app.name)
                } icon: {
                    Image(nsImage: ExternalApps.icon(app.path))
                }
            }
        }
        if apps.defaultApp == nil && apps.others.isEmpty {
            Text(urls.count > 1 ? String(localized: "没有能同时打开这些文件的 App") : String(localized: "没有找到能打开的 App"))
        }
        Divider()
        Button("其他…") {
            let list = urls
            DispatchQueue.main.async { ExternalApps.chooseOther(for: list) }
        }
    }

    private func open(_ app: OpenWithLogic.App) {
        ExternalApps.open(urls, with: URL(fileURLWithPath: app.path), name: app.name)
    }
}

/// 设置 › 通用 ›「在终端 / 编辑器中打开」：右键「在终端打开」「在编辑器打开」用哪个 App（只列这台 Mac 上装了的）。
struct ExternalToolsSection: View {
    @AppStorage(ExternalApps.terminalKey) private var terminal = ""
    @AppStorage(ExternalApps.editorKey) private var editor = ""
    @State private var terminals: [ExternalTool] = []
    @State private var editors: [ExternalTool] = []

    var body: some View {
        Section("在终端 / 编辑器中打开") {
            Picker("终端", selection: $terminal) {
                Text("终端（系统自带）").tag("")
                ForEach(terminals.filter { $0.id != ExternalToolCatalog.terminals[0].id }) { tool in
                    Text(verbatim: tool.name).tag(tool.id)
                }
            }
            Picker("编辑器", selection: $editor) {
                Text("自动（\(editors.first?.name ?? String(localized: "文本编辑"))）").tag("")
                ForEach(editors) { tool in
                    Text(verbatim: tool.name).tag(tool.id)
                }
            }
            Text("右键「在终端打开」：文件夹直接打开，文件打开它所在的文件夹。「在编辑器打开」认得 VS Code、Cursor、Zed、Sublime Text、Xcode 和文本编辑（文本编辑打不开文件夹）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            terminals = ExternalApps.installed(ExternalToolCatalog.terminals)
            editors = ExternalApps.installed(ExternalToolCatalog.editors)
        }
    }
}
