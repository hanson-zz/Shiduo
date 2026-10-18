import Foundation

/// 图中文字缓存的键：「路径|修改时间（整数秒）」。纯逻辑，单元测试直接调用。
enum OCRCacheKeys {
    static func key(path: String, modified: Date?) -> String {
        path + "|" + String(Int(modified?.timeIntervalSince1970 ?? 0))
    }

    /// 拆成 (路径, 修改时间)。路径里本身可能有「|」，按最后一个拆。
    static func split(_ key: String) -> (path: String, seconds: String)? {
        guard let bar = key.lastIndex(of: "|") else { return nil }
        return (String(key[..<bar]), String(key[key.index(after: bar)...]))
    }

    /// 同一路径只留修改时间最新的那条。
    static func latestPerPath(_ texts: [String: String]) -> [String: String] {
        var best: [String: (key: String, seconds: Int)] = [:]
        for key in texts.keys {
            guard let parts = split(key) else { continue }
            let value = Int(parts.seconds) ?? 0
            if let current = best[parts.path], current.seconds >= value { continue }
            best[parts.path] = (key, value)
        }
        var result: [String: String] = [:]
        for (_, entry) in best { result[entry.key] = texts[entry.key] }
        return result
    }
}
