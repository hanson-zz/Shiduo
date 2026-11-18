import Foundation

/// 版本号比较（语义化版本 + 测试版后缀）：0.14.2-beta.1 > 0.14.1 > 0.14.1-beta.10 > 0.14.1-beta.9。
/// 以前用字符串 `.numeric` 比较，会把 0.14.1 当成比 0.14.1-beta.10 小，测试版用户收不到正式版提示。
struct AppVersion: Comparable, CustomStringConvertible {
    /// 主.次.补丁（缺的补 0）。
    let core: [Int]
    /// 「-」后面按「.」分开的测试版标识，例如 ["beta", "10"]；正式版为空。
    let prerelease: [String]

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// 接受「v0.14.1」「0.14.1-beta.10」「0.14」「0.14.1+5」（构建元数据忽略）。认不出来时返回 nil。
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        let corePart: Substring
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            corePart = text[..<dash]
            let rest = text[text.index(after: dash)...]
            pre = rest.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if pre.isEmpty || pre.contains(where: \.isEmpty) { return nil }
        } else {
            corePart = Substring(text)
        }
        let numbers = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard !numbers.isEmpty, numbers.count <= 4 else { return nil }
        var parsed: [Int] = []
        for n in numbers {
            guard let v = Int(n), v >= 0 else { return nil }
            parsed.append(v)
        }
        while parsed.count < 3 { parsed.append(0) }
        core = parsed
        prerelease = pre
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ a: AppVersion, _ b: AppVersion) -> Int {
        let count = max(a.core.count, b.core.count)
        for i in 0..<count {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        // 同一个主.次.补丁：正式版比任何测试版都新。
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        default: break
        }
        for i in 0..<min(a.prerelease.count, b.prerelease.count) {
            let x = a.prerelease[i], y = b.prerelease[i]
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (xi?, yi?): return xi < yi ? -1 : 1          // 纯数字按数值：beta.10 > beta.9
            case (.some, nil): return -1                           // 数字 < 字母
            case (nil, .some): return 1
            case (nil, nil): return x < y ? -1 : 1                 // 字母按 ASCII：alpha < beta < rc
            }
        }
        if a.prerelease.count == b.prerelease.count { return 0 }
        return a.prerelease.count < b.prerelease.count ? -1 : 1
    }
}

/// 从 GitHub Release 列表里挑出该提示的更新（纯逻辑，方便测试）。
enum UpdateSelection {
    struct Candidate: Equatable {
        let tag: String
        let isDraft: Bool
        let isPrerelease: Bool
    }

    /// 正在用测试版时才看测试版：测试版用户能收到更新的测试版和正式版；正式版用户永远只看正式版。
    static func wantsPrereleases(currentVersion: String) -> Bool {
        AppVersion(currentVersion)?.isPrerelease ?? false
    }

    /// 返回比当前版本新、且这个用户该看到的最高版本；没有则 nil。草稿永远不算。
    static func best(from candidates: [Candidate], currentVersion: String) -> Candidate? {
        guard let current = AppVersion(currentVersion) else { return nil }
        let allowPre = current.isPrerelease
        var best: (Candidate, AppVersion)?
        for c in candidates where !c.isDraft {
            guard let v = AppVersion(c.tag) else { continue }
            // 标记为预发布、或者版本号带测试版后缀的，都当测试版。
            if (c.isPrerelease || v.isPrerelease) && !allowPre { continue }
            guard v > current else { continue }
            if best == nil || v > best!.1 { best = (c, v) }
        }
        return best?.0
    }
}
