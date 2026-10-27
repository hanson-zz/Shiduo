import Foundation

/// 智能清理「旧项目的 node_modules」：在个人文件夹里找 node_modules（不进资源库、隐藏文件夹、废纸篓、
/// 应用程序和各种包），所在项目（同层有 package.json）超过 N 天没有任何改动的才列出。
/// 不进 node_modules 里面找，所以嵌套在别的 node_modules 里的不会单独出现。纯逻辑 + 读文件夹，单元测试用临时文件夹。
enum NodeModulesLogic {
    struct Hit: Equatable, Sendable {
        /// node_modules 文件夹。
        let modulesPath: String
        /// 项目文件夹（node_modules 的上一层）。
        let projectPath: String
        var projectName: String { (projectPath as NSString).lastPathComponent }
        /// 项目里（不算 node_modules）最新的改动时间。
        let lastModified: Date
    }

    /// 个人文件夹第一层不进去的文件夹。
    static let skippedTopLevel: Set<String> = ["Library", "Applications"]

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey]

    /// 找出旧项目的 node_modules。maxDepth：从个人文件夹往下最多几层；maxFolders：最多看多少个文件夹（防止跑太久）。
    static func findStale(home: String, now: Date = Date(), staleDays: Int = 90,
                          maxDepth: Int = 10, maxFolders: Int = 200_000,
                          fileManager fm: FileManager = .default,
                          isCancelled: () -> Bool = { false }) -> [Hit] {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        var hits: [Hit] = []
        var stack: [(URL, Int)] = [(URL(fileURLWithPath: home, isDirectory: true), 0)]
        var visited = 0
        while let entry = stack.popLast() {
            let (dir, depth) = entry
            if isCancelled() || visited >= maxFolders { break }
            visited += 1
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true
                else { continue }
                let name = child.lastPathComponent
                if depth == 0 && skippedTopLevel.contains(name) { continue }
                if name == "node_modules" {
                    let project = dir
                    guard fm.fileExists(atPath: project.appendingPathComponent("package.json").path) else { continue }
                    if let last = lastModifiedIfStale(project: project, cutoff: cutoff, fileManager: fm) {
                        hits.append(Hit(modulesPath: child.path, projectPath: project.path, lastModified: last))
                    }
                    continue
                }
                if depth + 1 < maxDepth { stack.append((child, depth + 1)) }
            }
        }
        return hits.sorted { $0.modulesPath < $1.modulesPath }
    }

    /// 项目里（不算任何 node_modules，算隐藏文件，比如 .git）所有东西都早于 cutoff 时返回最新的那个时间；
    /// 有任何一个新于 cutoff、读不了，或者东西太多没看完，都返回 nil（拿不准就不列）。
    static func lastModifiedIfStale(project: URL, cutoff: Date, entryLimit: Int = 20_000,
                                    fileManager fm: FileManager = .default) -> Date? {
        var newest = (try? project.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if newest >= cutoff { return nil }
        var stack: [URL] = [project]
        var seen = 0
        while let dir = stack.popLast() {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else {
                return nil
            }
            for child in children {
                seen += 1
                if seen > entryLimit { return nil }
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
                if values.isDirectory == true && values.isSymbolicLink != true && child.lastPathComponent == "node_modules" {
                    continue
                }
                let date = values.contentModificationDate ?? .distantPast
                if date >= cutoff { return nil }
                if date > newest { newest = date }
                if values.isDirectory == true && values.isSymbolicLink != true { stack.append(child) }
            }
        }
        return newest == .distantPast ? nil : newest
    }

    /// 多少天没改动（显示用）。
    static func daysSince(_ date: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}
