import Foundation

/// 「深度清理（搭配 Mole）」的纯逻辑部分：找 mo、解析版本、比较版本、生成终端脚本、解析 `mo analyze --json`。
///
/// Mole（github.com/tw93/Mole）是 GPL-3.0 的独立开源软件。拾掇不包含、不分发、不下载它的任何代码，
/// 只在用户自己装好之后，把它当成外部命令行程序调用（`mo`）。
enum MoleLogic {
    /// GUI App 拿不到 shell 的 PATH，只在这几个 Mole 官方安装方式会放 `mo` 的地方找。
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static let homepage = URL(string: "https://github.com/tw93/Mole")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/tw93/Mole/releases/latest")!
    static let brewInstall = "brew install mole"
    static let scriptInstall = "curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash"

    /// 按顺序列出可能的 `mo` 路径（`~` 展开成 home）。
    static func candidatePaths(home: String) -> [String] {
        searchDirectories.map { dir in
            let expanded = dir.hasPrefix("~") ? home + String(dir.dropFirst()) : dir
            return (expanded as NSString).appendingPathComponent("mo")
        }
    }

    // MARK: 版本

    /// 去掉终端颜色码（ESC[...m）。
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// 从 `mo --version` 的输出里取版本号。
    /// 输出形如 "\nMole version 1.61.0\nmacOS: 15.3\n…"，优先认 "Mole version x.y.z" 这一行，
    /// 没有这一行时（老版本 / 格式变了）才取第一个像版本号的词。
    static func parseVersion(_ output: String) -> String? {
        let text = stripANSI(output)
        let number = "([0-9]+(?:\\.[0-9]+)+)"
        if let r = text.range(of: "[Mm]ole[^\\n0-9]*?[Vv]?" + number, options: .regularExpression) {
            return firstMatch(number, in: String(text[r]))
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            // 跳过 macOS: / Kernel: 这类系统信息行
            if l.contains(":") { continue }
            if let v = firstMatch("[Vv]?" + number, in: l) { return normalizeTag(v) }
        }
        return nil
    }

    /// `mo --version` 里 "Install: Homebrew" 一行。
    static func reportsHomebrew(_ output: String) -> Bool {
        stripANSI(output).split(whereSeparator: \.isNewline).contains { line in
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("install:") && l.contains("homebrew")
        }
    }

    /// 符号链接解析后的真实路径在 Homebrew 的 Cellar 里，就是 brew 装的。
    static func isHomebrewPath(_ resolvedPath: String) -> Bool {
        resolvedPath.contains("/Cellar/") || resolvedPath.hasPrefix("/opt/homebrew/Caskroom/")
            || resolvedPath.hasPrefix("/usr/local/Caskroom/")
    }

    /// "V1.61.0" / "v1.61.0" → "1.61.0"
    static func normalizeTag(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        return t
    }

    /// 按数字逐段比较："1.10.0" 比 "1.9.9" 新，"1.61" 等于 "1.61.0"；带 -beta 之类的后缀只比前面的数字。
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = components(normalizeTag(a)), pb = components(normalizeTag(b))
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard !components(normalizeTag(latest)).isEmpty, !components(normalizeTag(current)).isEmpty else { return false }
        return compareVersions(latest, current) == .orderedDescending
    }

    private static func components(_ v: String) -> [Int] {
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? ""
        var out: [Int] = []
        for part in core.split(separator: ".") {
            guard let n = Int(part) else { break }
            out.append(n)
        }
        return out
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let idx = m.numberOfRanges > 1 ? 1 : 0
        guard let r = Range(m.range(at: idx), in: text) else { return nil }
        return String(text[r])
    }

    /// GitHub releases/latest 的 JSON → 版本号。
    static func parseLatestRelease(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let v = normalizeTag(tag)
        return components(v).isEmpty ? nil : v
    }

    // MARK: 终端脚本

    enum TerminalAction: Equatable {
        case clean, purge, analyze
        case install(brew: String?)
        case update(viaHomebrew: Bool, brew: String?)
    }

    /// 界面上要用到的几句话，由调用方按当前语言传进来（纯逻辑里不碰本地化）。
    struct ScriptText {
        var header: String
        var confirmClean: String
        var pressAnyKey: String
    }

    /// 单引号转义，给 bash 用。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 要在终端里执行的命令（给用户看，也写进脚本）。
    static func commands(for action: TerminalAction, mo: String) -> [String] {
        let m = shellQuote(mo)
        switch action {
        case .clean: return ["\(m) clean --dry-run", "\(m) clean"]
        case .purge: return ["\(m) purge"]
        case .analyze: return ["\(m) analyze"]
        case .install(let brew):
            if let brew { return ["\(shellQuote(brew)) install mole"] }
            return [scriptInstall]
        case .update(let viaHomebrew, let brew):
            if viaHomebrew, let brew { return ["\(shellQuote(brew)) upgrade mole"] }
            return ["\(m) update"]
        }
    }

    /// 生成 .command 脚本：Terminal.app 打开它就会执行，不需要 AppleScript / 自动化权限。
    static func script(for action: TerminalAction, mo: String, text: ScriptText) -> String {
        let cmds = commands(for: action, mo: mo)
        var body: [String] = [
            "#!/bin/bash",
            "# Generated by Shiduo. Runs Mole (github.com/tw93/Mole), a separately installed GPL-3.0 tool.",
            "rm -f \"$0\"",
            "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH\"",
            "clear",
            "echo \(shellQuote(text.header))",
            "echo",
        ]
        switch action {
        case .clean:
            body += [
                cmds[0],
                "echo",
                "read -r -p \(shellQuote(text.confirmClean)) _ || exit 0",
                cmds[1],
            ]
        default:
            body += cmds
        }
        body += [
            "echo",
            "read -r -n 1 -s -p \(shellQuote(text.pressAnyKey)) _",
            "echo",
        ]
        return body.joined(separator: "\n") + "\n"
    }

    // MARK: mo analyze --json

    struct AnalyzeEntry: Equatable, Identifiable {
        var id: String { path }
        let name: String
        let path: String
        let size: Int64
        let isDirectory: Bool
        let partial: Bool
    }

    struct AnalyzeReport: Equatable {
        let path: String
        let entries: [AnalyzeEntry]
        let largeFiles: [AnalyzeEntry]
        let totalSize: Int64?
        let partial: Bool
    }

    /// 宽松解析：缺字段的条目跳过；顶层不是对象或连 entries 都没有就返回 nil（调用方退回终端）。
    static func parseAnalyze(_ data: Data) -> AnalyzeReport? {
        guard let obj = jsonObject(in: data) else { return nil }
        let rawEntries = obj["entries"] as? [[String: Any]]
        let rawLarge = obj["large_files"] as? [[String: Any]]
        guard rawEntries != nil || rawLarge != nil else { return nil }
        func entry(_ d: [String: Any], defaultDir: Bool) -> AnalyzeEntry? {
            guard let path = d["path"] as? String, !path.isEmpty else { return nil }
            let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
            let size = int64(d["size"]) ?? 0
            let isDir = (d["is_dir"] as? Bool) ?? defaultDir
            let status = (d["scan_status"] as? String)?.lowercased()
            return AnalyzeEntry(name: name, path: path, size: max(size, 0), isDirectory: isDir,
                                partial: status == "partial" || status == "unavailable")
        }
        let entries = (rawEntries ?? []).compactMap { entry($0, defaultDir: true) }.sorted { $0.size > $1.size }
        let large = (rawLarge ?? []).compactMap { entry($0, defaultDir: false) }.sorted { $0.size > $1.size }
        let status = (obj["scan_status"] as? String)?.lowercased()
        return AnalyzeReport(path: obj["path"] as? String ?? "", entries: entries, largeFiles: large,
                             totalSize: int64(obj["total_size"]),
                             partial: status == "partial" || status == "unavailable")
    }

    /// 输出前面可能混着一两行提示文字，从第一个 "{" 开始解析。
    private static func jsonObject(in data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        guard let brace = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data[brace...]) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}
