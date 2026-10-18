import AppKit
import Foundation

struct UpdateInfo: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let url: URL
    /// Release 里的 ZIP 包，用于自动更新。
    let zipURL: URL?
}

/// 检查更新：只访问 GitHub 上本项目的 Release。拾掇另外只在激活 / 校验 Pro 授权时联网（见 Sources/Pro/License.swift）。
enum UpdateChecker {
    static let repoURL = URL(string: "https://github.com/hanson-zz/Shiduo")!
    static let apiURL = URL(string: "https://api.github.com/repos/hanson-zz/Shiduo/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    enum Outcome {
        case upToDate
        case available(UpdateInfo)
        case failed
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let response = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let html = object["html_url"] as? String,
              let url = URL(string: html)
        else { return .failed }
        let assets = object["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        let zipURL = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if latest.compare(currentVersion, options: .numeric) == .orderedDescending {
            return .available(UpdateInfo(version: latest, url: url, zipURL: zipURL))
        }
        return .upToDate
    }
}

/// 自动更新：每天检查一次，有新版本就在后台下载并解压，退出拾掇时替换旧版本。
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    @Published var state: State = .idle

    /// 已解压、等待安装的新版本。
    private var stagedApp: URL?

    static var autoCheck: Bool {
        UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true
    }

    static var autoInstall: Bool {
        UserDefaults.standard.object(forKey: "autoInstallUpdates") as? Bool ?? true
    }

    /// 启动时调用：距离上次检查超过一天才联网。
    func checkOnLaunch() async -> UpdateInfo? {
        guard Self.autoCheck else { return nil }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return nil }
        return await checkNow(manual: false)
    }

    /// 立即检查；开启了自动安装时直接开始下载。返回需要提示用户的新版本（自动安装时为 nil）。
    @discardableResult
    func checkNow(manual: Bool) async -> UpdateInfo? {
        state = .checking
        let outcome = await UpdateChecker.check()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        switch outcome {
        case .upToDate:
            state = .idle
            return nil
        case .failed:
            state = manual ? .failed(String(localized: "检查失败，请稍后再试")) : .idle
            return nil
        case .available(let info):
            if Self.autoInstall, let zip = info.zipURL, canReplaceSelf {
                await download(info, zip: zip)
                return nil
            }
            state = .idle
            return info
        }
    }

    /// 从 DMG 里直接运行（App Translocation）或没有写权限时，不能自动替换。
    var canReplaceSelf: Bool {
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") || bundle.path.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    private func download(_ info: UpdateInfo, zip: URL) async {
        state = .downloading(info.version)
        do {
            let (temp, _) = try await URLSession.shared.download(from: zip)
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShiduoUpdate-\(info.version)", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: temp, to: archive)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archive.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            let contents = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            guard let app = contents.first(where: { $0.pathExtension == "app" }),
                  Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
            else {
                state = .failed(String(localized: "下载的更新包不完整"))
                return
            }
            stagedApp = app
            state = .ready(info.version)
        } catch {
            state = .failed(String(localized: "下载更新失败"))
        }
    }

    /// 退出时调用：交给一个小脚本，等拾掇退出后替换应用。
    func installIfReady() {
        guard let staged = stagedApp, canReplaceSelf else { return }
        let target = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target).old"
        mv "\(target)" "\(target).old" && /usr/bin/ditto "\(staged.path)" "\(target)" && rm -rf "\(target).old" || mv "\(target).old" "\(target)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var updater: Updater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 拾掇 Pro 介绍页用独立窗口：主窗口关着也能弹出（见 PaywallWindow）。
            PaywallWindow.shared.start()
            // 通知代理、授权状态联动、定时刷新授权：不依赖主窗口。
            AppLifecycle.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.updater?.installIfReady()
        }
    }
}
