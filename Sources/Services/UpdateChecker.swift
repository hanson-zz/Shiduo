import Foundation

struct UpdateInfo: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let url: URL
}

/// 可选的更新检查（默认关闭）。这是拾掇唯一会联网的地方，只读取 GitHub 上的最新版本号。
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
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if latest.compare(currentVersion, options: .numeric) == .orderedDescending {
            return .available(UpdateInfo(version: latest, url: url))
        }
        return .upToDate
    }
}
