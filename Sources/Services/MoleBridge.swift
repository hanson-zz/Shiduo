import AppKit
import Foundation

/// 用户自己装好的 Mole（`mo`）的信息。
struct MoleInstall: Equatable {
    let path: String
    let version: String?
    let viaHomebrew: Bool
}

/// 调用用户另外安装的 Mole 命令行工具（github.com/tw93/Mole，GPL-3.0）。
/// 拾掇不带 Mole 的任何代码：检测 / 读版本 / 读 `mo analyze --json` 在后台用 Process 跑，
/// 需要交互的命令（清理、卸载、项目文件夹）写成临时 .command 脚本交给“终端”执行，由 Mole 自己提示确认。
///
/// 联网：只在清理页的 Mole 卡片显示出来（并且 Mole 已安装）时，或者用户点「检查更新」时，
/// 访问一次 GitHub 上 tw93/Mole 的 releases/latest，结果缓存 24 小时，失败就当没有新版本。
@MainActor
final class MoleBridge: ObservableObject {
    static let shared = MoleBridge()

    enum Status: Equatable {
        case unknown
        case checking
        case notInstalled
        case installed(MoleInstall)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var latestVersion: String?
    @Published private(set) var checkingLatest = false

    private var lastDetect: Date = .distantPast
    private var detecting = false
    private static let latestKey = "moleLatestVersion"
    private static let latestCheckedKey = "moleLatestCheckedAt"

    private init() {
        latestVersion = UserDefaults.standard.string(forKey: Self.latestKey)
    }

    var install: MoleInstall? {
        if case .installed(let i) = status { return i }
        return nil
    }

    /// 已安装且 GitHub 上有更新的版本。
    var availableUpdate: String? {
        guard let current = install?.version, let latest = latestVersion,
              MoleLogic.isNewer(latest, than: current) else { return nil }
        return latest
    }

    nonisolated static var brewPath: String? {
        MoleLogic.brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: 检测

    /// 重新找 `mo` 并读版本。`force` 为 false 时 3 秒内不重复跑（App 激活时会频繁调用）。
    func detect(force: Bool = true) async {
        if !force, Date().timeIntervalSince(lastDetect) < 3 { return }
        if detecting { return }
        detecting = true
        defer { detecting = false }
        lastDetect = Date()
        // 已安装时保留原来的显示，后台悄悄重新读；没装 / 还不知道时显示“正在检测”。
        if install == nil { status = .checking }
        let found = await Task.detached(priority: .userInitiated) { Self.locateAndProbe() }.value
        status = found.map(Status.installed) ?? .notInstalled
        lastDetect = Date()
        if found != nil { await refreshLatest(force: false) }
    }

    nonisolated private static func locateAndProbe() -> MoleInstall? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        guard let path = MoleLogic.candidatePaths(home: home).first(where: { fm.isExecutableFile(atPath: $0) })
        else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let result = runCapturing(path, ["--version"], timeout: 15)
        let output = result?.output ?? ""
        let version = MoleLogic.parseVersion(output)
        let brew = MoleLogic.isHomebrewPath(resolved) || MoleLogic.reportsHomebrew(output)
        return MoleInstall(path: path, version: version, viaHomebrew: brew)
    }

    /// 后台跑一个命令并取输出（输出写到临时文件，避免管道写满卡住）；超时就结束它。
    nonisolated static func runCapturing(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shiduo-mole-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        guard let handle = try? FileHandle(forWritingTo: out) else { return nil }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { try? handle.close(); return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            killTree(process)
            _ = done.wait(timeout: .now() + 2)
        }
        try? handle.close()
        let data = (try? Data(contentsOf: out)) ?? Data()
        return (process.isRunning ? -1 : process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// GUI App 没有 shell 的 PATH；补上 Homebrew 和 ~/.local/bin，关掉颜色和交互。
    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        env["HOME"] = home
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    /// 结束进程和它的子进程（mo 是 shell 脚本，真正干活的是它启动的子进程）。
    nonisolated static func killTree(_ process: Process) {
        guard process.isRunning else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }

    // MARK: 新版本

    /// 查 GitHub 上 Mole 的最新版本：24 小时内查过就用缓存（`force` 时跳过缓存）。失败不提示。
    func refreshLatest(force: Bool) async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.latestCheckedKey)
        if !force {
            // 用户在设置里关掉了「检查更新」时，不自动联网，只在点「检查更新」时查。
            let autoCheck = defaults.object(forKey: "checkUpdates") as? Bool ?? true
            guard autoCheck, Date().timeIntervalSince1970 - last > 86_400 else { return }
        }
        guard !checkingLatest else { return }
        checkingLatest = true
        defer { checkingLatest = false }
        var request = URLRequest(url: MoleLogic.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let response = try? await URLSession.shared.data(for: request),
              (response.1 as? HTTPURLResponse)?.statusCode == 200,
              let version = MoleLogic.parseLatestRelease(response.0)
        else { return }
        latestVersion = version
        defaults.set(version, forKey: Self.latestKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.latestCheckedKey)
    }

    // MARK: 终端

    /// 给用户看的命令（确认框里显示）。
    func displayCommands(for action: MoleLogic.TerminalAction) -> String {
        MoleLogic.commands(for: action, mo: install?.path ?? "mo")
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .joined(separator: "\n")
    }

    /// 把命令写进临时 .command 脚本，用“终端”打开执行。
    func runInTerminal(_ action: MoleLogic.TerminalAction) {
        let mo = install?.path ?? "mo"
        let shown = MoleLogic.commands(for: action, mo: "mo").map { $0.replacingOccurrences(of: "'", with: "") }
        let text = MoleLogic.ScriptText(
            header: String(localized: "拾掇正在用终端运行 Mole（你另外安装的开源工具）：\(shown.joined(separator: " → "))"),
            confirmClean: String(localized: "上面是预览。确认清理请按回车，不想清理就直接关掉这个窗口… "),
            pressAnyKey: String(localized: "完成。按任意键关闭，回到拾掇后会自动重新检测… ")
        )
        let script = MoleLogic.script(for: action, mo: mo, text: text)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Shiduo-Mole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mole-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 「磁盘分析」：后台跑 `mo analyze --json <文件夹>`，在拾掇里列出最占地方的文件夹和大文件。
@MainActor
final class MoleAnalyzeModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running(Date)
        case done(MoleLogic.AnalyzeReport)
        case failed
    }

    @Published private(set) var state: State = .idle
    private var process: Process?
    private var cancelled = false

    func start(mo: String, folder: URL) {
        cancel()
        cancelled = false
        state = .running(Date())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mo)
        process.arguments = ["analyze", "--json", folder.path]
        process.environment = MoleBridge.environment()
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shiduo-mole-analyze-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: out) else { state = .failed; return }
        process.standardOutput = handle
        process.terminationHandler = { [weak self] p in
            try? handle.close()
            let data = (try? Data(contentsOf: out)) ?? Data()
            try? FileManager.default.removeItem(at: out)
            let report = MoleLogic.parseAnalyze(data)
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process === p else { return }
                self.process = nil
                if self.cancelled { self.state = .idle; return }
                if let report, status == 0 || !report.entries.isEmpty {
                    self.state = .done(report)
                } else {
                    self.state = .failed
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            try? handle.close()
            state = .failed
        }
    }

    func cancel() {
        guard let process else { return }
        cancelled = true
        let p = process
        Task.detached { MoleBridge.killTree(p) }
        state = .idle
    }
}
