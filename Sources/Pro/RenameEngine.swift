import Foundation

// 拾掇 Pro：批量改名增强的规则引擎（纯逻辑，单元测试直接编译）。
// 规则从上往下依次作用在「主名」上（扩展名不动）：查找替换（可选正则，$1 引用分组）、加序号、加日期、
// 加前缀 / 后缀、去掉空格、大小写、去掉「副本」/「 2」。预览时就把非法名字和重名标出来，有问题不让改。

enum RenamePosition: String, Codable, CaseIterable {
    case prefix, suffix
}

enum RenameLetterCase: String, Codable, CaseIterable {
    case lower, upper, capitalized
}

enum RenameDateSource: String, Codable, CaseIterable {
    /// 修改日期。
    case modified
    /// 创建日期。
    case created
    /// 拍摄日期（照片的 EXIF；没有时用创建 / 修改日期）。
    case captured
    /// 今天。
    case today
}

/// 一条规则。字段是平铺的（界面直接绑定），不用的字段忽略；读旧预设时缺的字段用默认值。
struct RenameStep: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case replace, sequence, date, affix, spaces, letterCase, removeCopySuffix
    }

    var id = UUID()
    var kind: Kind
    // 查找替换
    var find = ""
    var replacement = ""
    var useRegex = false
    var caseSensitive = false
    // 序号 / 日期放在哪、用什么连接
    var position: RenamePosition = .prefix
    var separator = "_"
    // 序号
    var start = 1
    var step = 1
    var digits = 3
    // 日期
    var dateSource: RenameDateSource = .modified
    var dateFormat = "yyyy-MM-dd"
    // 前缀 / 后缀
    var prefix = ""
    var suffix = ""
    // 空格换成什么（"" 表示去掉）
    var spaceReplacement = ""
    // 大小写
    var letterCase: RenameLetterCase = .lower

    init(kind: Kind) { self.kind = kind }

    private enum CodingKeys: String, CodingKey {
        case kind, find, replacement, useRegex, caseSensitive, position, separator, start, step, digits
        case dateSource, dateFormat, prefix, suffix, spaceReplacement, letterCase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        useRegex = try c.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        position = try c.decodeIfPresent(RenamePosition.self, forKey: .position) ?? .prefix
        separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? "_"
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 1
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 3
        dateSource = try c.decodeIfPresent(RenameDateSource.self, forKey: .dateSource) ?? .modified
        dateFormat = try c.decodeIfPresent(String.self, forKey: .dateFormat) ?? "yyyy-MM-dd"
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        spaceReplacement = try c.decodeIfPresent(String.self, forKey: .spaceReplacement) ?? ""
        letterCase = try c.decodeIfPresent(RenameLetterCase.self, forKey: .letterCase) ?? .lower
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(find, forKey: .find)
        try c.encode(replacement, forKey: .replacement)
        try c.encode(useRegex, forKey: .useRegex)
        try c.encode(caseSensitive, forKey: .caseSensitive)
        try c.encode(position, forKey: .position)
        try c.encode(separator, forKey: .separator)
        try c.encode(start, forKey: .start)
        try c.encode(step, forKey: .step)
        try c.encode(digits, forKey: .digits)
        try c.encode(dateSource, forKey: .dateSource)
        try c.encode(dateFormat, forKey: .dateFormat)
        try c.encode(prefix, forKey: .prefix)
        try c.encode(suffix, forKey: .suffix)
        try c.encode(spaceReplacement, forKey: .spaceReplacement)
        try c.encode(letterCase, forKey: .letterCase)
    }

    /// 比较规则内容时不看 id（预设和当前规则是不是同一套）。
    func sameContent(as other: RenameStep) -> Bool {
        var a = self
        a.id = other.id
        return a == other
    }
}

/// 一组规则，起个名字存下来。
struct RenamePreset: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var steps: [RenameStep]
}

/// 要改名的一个文件。
struct RenameInput: Hashable {
    var name: String
    /// 所在文件夹（同一文件夹里的才互相比重名）。
    var directory: String
    var isDirectory = false
    var modified: Date?
    var created: Date?
    var captured: Date?
}

enum RenameIssue: Equatable {
    /// 名字不能用（空、有「/」或「:」、以「.」开头、太长）。
    case illegal
    /// 和这一批里别的文件改成了同一个名字。
    case duplicate
    /// 和文件夹里已有（不在这一批里）的文件重名：自动加「 (1)」。
    case existing
}

struct RenameOutcome: Equatable {
    var original: String
    var newName: String
    var issue: RenameIssue?
    var changed: Bool { newName != original }
}

struct RenameResult: Equatable {
    var outcomes: [RenameOutcome]
    /// 正则写错了（出错时所有名字保持不变）。
    var regexError: String?

    /// 有改动、正则没错、没有非法名字和互相重名才能改。
    var canApply: Bool {
        regexError == nil && outcomes.contains(where: \.changed)
            && !outcomes.contains { $0.issue == .illegal || $0.issue == .duplicate }
    }

    var problemCount: Int { outcomes.filter { $0.issue == .illegal || $0.issue == .duplicate }.count }
}

enum RenameEngine {
    /// existing：每个文件夹里已有的名字（小写，可以包括这一批的原名，会自动排除）。
    static func run(_ inputs: [RenameInput], steps: [RenameStep], existing: [String: Set<String>] = [:],
                    today: Date = Date()) -> RenameResult {
        // 先检查正则。
        for step in steps where step.kind == .replace && step.useRegex && !step.find.isEmpty {
            if let message = regexError(step.find, caseSensitive: step.caseSensitive) {
                return RenameResult(outcomes: inputs.map { RenameOutcome(original: $0.name, newName: $0.name) }, regexError: message)
            }
        }
        var names: [String] = []
        for (index, input) in inputs.enumerated() {
            let (stem, ext) = split(input)
            var current = stem
            for step in steps { current = apply(step, to: current, index: index, input: input, today: today) }
            names.append(ext.isEmpty ? current : current + "." + ext)
        }

        var outcomes = zip(inputs, names).map { RenameOutcome(original: $0.name, newName: $1) }
        // 非法名字。
        for i in outcomes.indices where outcomes[i].changed && !isLegal(outcomes[i].newName, original: inputs[i].name) {
            outcomes[i].issue = .illegal
        }
        // 这一批里互相重名（同一文件夹、不分大小写，和访达一样）。
        var groups: [String: [Int]] = [:]
        for (i, outcome) in outcomes.enumerated() {
            groups[inputs[i].directory + "/" + outcome.newName.lowercased(), default: []].append(i)
        }
        for (_, members) in groups where members.count > 1 {
            for i in members where outcomes[i].issue == nil { outcomes[i].issue = .duplicate }
        }
        // 和文件夹里其他文件重名：自动加「 (1)」「 (2)」……（效果图：和已有文件重名，会自动加 (1)）。
        var originals: [String: Set<String>] = [:]
        for input in inputs { originals[input.directory, default: []].insert(input.name.lowercased()) }
        var taken: [String: Set<String>] = [:]
        for (i, outcome) in outcomes.enumerated() {
            taken[inputs[i].directory, default: []].insert(outcome.newName.lowercased())
        }
        for i in outcomes.indices where outcomes[i].changed && outcomes[i].issue == nil {
            let dir = inputs[i].directory
            let others = (existing[dir] ?? []).subtracting(originals[dir] ?? [])
            guard others.contains(outcomes[i].newName.lowercased()) else { continue }
            let (stem, ext) = splitName(outcomes[i].newName, isDirectory: inputs[i].isDirectory)
            var n = 1
            func candidate() -> String { ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)" }
            while others.contains(candidate().lowercased()) || taken[dir]?.contains(candidate().lowercased()) == true { n += 1 }
            outcomes[i].newName = candidate()
            taken[dir, default: []].insert(outcomes[i].newName.lowercased())
            outcomes[i].issue = .existing
        }
        return RenameResult(outcomes: outcomes, regexError: nil)
    }

    static func split(_ input: RenameInput) -> (stem: String, ext: String) {
        splitName(input.name, isDirectory: input.isDirectory)
    }

    /// 主名和扩展名（文件夹整个名字都是主名；「.zshrc」这种没有主名的也整个算主名）。
    static func splitName(_ name: String, isDirectory: Bool) -> (stem: String, ext: String) {
        guard !isDirectory else { return (name, "") }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !ext.isEmpty, !stem.isEmpty else { return (name, "") }
        return (stem, ext)
    }

    static func apply(_ step: RenameStep, to stem: String, index: Int, input: RenameInput, today: Date) -> String {
        switch step.kind {
        case .replace:
            guard !step.find.isEmpty else { return stem }
            if step.useRegex {
                guard let regex = try? NSRegularExpression(pattern: step.find, options: step.caseSensitive ? [] : [.caseInsensitive]) else {
                    return stem
                }
                let range = NSRange(stem.startIndex..., in: stem)
                return regex.stringByReplacingMatches(in: stem, options: [], range: range, withTemplate: step.replacement)
            }
            return stem.replacingOccurrences(of: step.find, with: step.replacement,
                                             options: step.caseSensitive ? [] : [.caseInsensitive])
        case .sequence:
            let number = step.start + index * step.step
            let text = number < 0 ? String(number) : String(format: "%0\(max(1, min(step.digits, 8)))d", number)
            return attach(text, to: stem, position: step.position, separator: step.separator)
        case .date:
            let date: Date
            switch step.dateSource {
            case .modified: date = input.modified ?? input.created ?? today
            case .created: date = input.created ?? input.modified ?? today
            case .captured: date = input.captured ?? input.created ?? input.modified ?? today
            case .today: date = today
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = step.dateFormat.isEmpty ? "yyyy-MM-dd" : step.dateFormat
            return attach(formatter.string(from: date), to: stem, position: step.position, separator: step.separator)
        case .affix:
            return step.prefix + stem + step.suffix
        case .spaces:
            // 连续的空格（含全角空格）当一个处理，首尾的直接去掉。
            let parts = stem.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
            return parts.joined(separator: step.spaceReplacement)
        case .letterCase:
            switch step.letterCase {
            case .lower: return stem.lowercased()
            case .upper: return stem.uppercased()
            case .capitalized: return stem.capitalized
            }
        case .removeCopySuffix:
            return removeCopySuffix(stem)
        }
    }

    private static func attach(_ text: String, to stem: String, position: RenamePosition, separator: String) -> String {
        guard !stem.isEmpty else { return text }
        return position == .prefix ? text + separator + stem : stem + separator + text
    }

    /// 去掉拷贝时加的尾巴：「 副本」「 副本 2」「 的副本」「 拷贝」「 copy」「 copy 3」「 (1)」「 2」（空格后 1–2 位数字）。
    static func removeCopySuffix(_ stem: String) -> String {
        let patterns = [
            "\\s*(的)?副本(\\s*\\d+)?$",
            "\\s+拷贝(\\s*\\d+)?$",
            "\\s+copy(\\s+\\d+)?$",
            "\\s*\\(\\d+\\)$",
            "\\s+\\d{1,2}$",
        ]
        var result = stem
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let replaced = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            if replaced != result, !replaced.trimmingCharacters(in: .whitespaces).isEmpty {
                result = replaced
                break
            }
        }
        return result
    }

    /// 正则写错时的说明；没错为 nil。
    static func regexError(_ pattern: String, caseSensitive: Bool) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
            return nil
        } catch {
            return String(localized: "正则表达式写得不对，请检查括号、方括号和转义符。")
        }
    }

    /// 能不能当文件名：不空、没有「/」「:」、不以「.」开头（原来就是隐藏文件的除外）、不超过 255 字节、不是「.」「..」。
    static func isLegal(_ name: String, original: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") || name.contains(":") { return false }
        if name.hasPrefix("."), !original.hasPrefix(".") { return false }
        if name.utf8.count > 255 { return false }
        // 只剩扩展名（「.jpg」）也不行。
        return true
    }
}

/// 内置的常用预设和用户自己存的预设。
enum RenamePresets {
    static let defaultsKey = "renamePresets.v1"

    static var builtIns: [RenamePreset] {
        var sequence = RenameStep(kind: .sequence)
        sequence.digits = 3
        sequence.separator = "_"

        var datePrefix = RenameStep(kind: .date)
        datePrefix.dateSource = .modified
        datePrefix.dateFormat = "yyyy-MM-dd"
        datePrefix.separator = "_"

        var captured = RenameStep(kind: .date)
        captured.dateSource = .captured
        captured.dateFormat = "yyyy-MM-dd"
        captured.separator = "_"

        var noSpaces = RenameStep(kind: .spaces)
        noSpaces.spaceReplacement = ""

        var underscores = RenameStep(kind: .spaces)
        underscores.spaceReplacement = "_"

        var lower = RenameStep(kind: .letterCase)
        lower.letterCase = .lower
        var upper = RenameStep(kind: .letterCase)
        upper.letterCase = .upper

        return [
            RenamePreset(id: "builtin.sequence", name: String(localized: "序号 001 前缀"), steps: [sequence]),
            RenamePreset(id: "builtin.date", name: String(localized: "日期前缀 yyyy-MM-dd"), steps: [datePrefix]),
            RenamePreset(id: "builtin.captured", name: String(localized: "拍摄日期前缀"), steps: [captured]),
            RenamePreset(id: "builtin.noSpaces", name: String(localized: "去掉空格"), steps: [noSpaces]),
            RenamePreset(id: "builtin.underscores", name: String(localized: "空格换成 _"), steps: [underscores]),
            RenamePreset(id: "builtin.lower", name: String(localized: "全部小写"), steps: [lower]),
            RenamePreset(id: "builtin.upper", name: String(localized: "全部大写"), steps: [upper]),
            RenamePreset(id: "builtin.copySuffix", name: String(localized: "去掉「副本」/「 2」"), steps: [RenameStep(kind: .removeCopySuffix)]),
        ]
    }

    static func decode(_ data: Data?) -> [RenamePreset] {
        guard let data, let list = try? JSONDecoder().decode([RenamePreset].self, from: data) else { return [] }
        return list
    }

    static func encode(_ presets: [RenamePreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }

    /// 上一次用的规则（规则模式下次打开接着用）。
    static func decodeSteps(_ data: Data?) -> [RenameStep]? {
        guard let data, !data.isEmpty, let steps = try? JSONDecoder().decode([RenameStep].self, from: data), !steps.isEmpty else { return nil }
        return steps
    }

    static func encodeSteps(_ steps: [RenameStep]) -> Data? {
        try? JSONEncoder().encode(steps)
    }

    /// 存一个新预设：同名的覆盖（规则换成新的），名字去掉首尾空格，空名字不存。
    static func saving(_ name: String, steps: [RenameStep], into list: [RenamePreset], newID: String = UUID().uuidString) -> [RenamePreset] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !steps.isEmpty else { return list }
        var result = list
        if let index = result.firstIndex(where: { $0.name == trimmed }) {
            result[index].steps = steps
        } else {
            result.append(RenamePreset(id: newID, name: trimmed, steps: steps))
        }
        return result
    }

    static func renaming(_ id: String, to name: String, in list: [RenamePreset]) -> [RenamePreset] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !list.contains(where: { $0.name == trimmed && $0.id != id }) else { return list }
        return list.map { preset in
            var copy = preset
            if copy.id == id { copy.name = trimmed }
            return copy
        }
    }

    static func deleting(_ id: String, from list: [RenamePreset]) -> [RenamePreset] {
        list.filter { $0.id != id }
    }
}
