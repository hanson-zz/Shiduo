import Foundation

// 拾掇 Pro：新建文件模板的纯逻辑（内置模板的内容、起名、列出模板文件夹），单元测试直接编译。

/// 内置模板：空白文本、Markdown、富文本、JSON、网页、Python、Shell（Shell 脚本建好就能执行）。
enum BuiltInTemplate: String, CaseIterable, Identifiable {
    case text, markdown, rtf, json, html, python, shell

    var id: String { rawValue }

    var ext: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .rtf: return "rtf"
        case .json: return "json"
        case .html: return "html"
        case .python: return "py"
        case .shell: return "sh"
        }
    }

    /// 菜单里的名字。
    var title: String {
        switch self {
        case .text: return String(localized: "纯文本 .txt")
        case .markdown: return String(localized: "Markdown .md")
        case .rtf: return String(localized: "富文本 .rtf")
        case .json: return String(localized: "JSON .json")
        case .html: return String(localized: "网页 .html")
        case .python: return String(localized: "Python 脚本 .py")
        case .shell: return String(localized: "Shell 脚本 .sh")
        }
    }

    /// 菜单里的小图标。
    var symbol: String {
        switch self {
        case .text: return "doc.plaintext"
        case .markdown: return "number"
        case .rtf: return "doc.richtext"
        case .json: return "curlybraces"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .python: return "terminal"
        case .shell: return "apple.terminal"
        }
    }

    /// 新文件叫「未命名.txt」（重名时「未命名 2.txt」）。
    var fileName: String { String(localized: "未命名") + "." + ext }

    /// Shell 脚本要能直接运行（chmod 755）。
    var isExecutable: Bool { self == .shell }

    var contents: Data {
        let text: String
        switch self {
        case .text: text = ""
        case .markdown: text = "# \n"
        case .rtf: text = "{\\rtf1\\ansi\\ansicpg936\\deff0{\\fonttbl{\\f0\\fnil PingFangSC-Regular;}}\\f0\\fs26 \\par}\n"
        case .json: text = "{\n  \n}\n"
        case .html:
            text = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title></title>
            </head>
            <body>

            </body>
            </html>

            """
        case .python: text = "#!/usr/bin/env python3\n\n"
        case .shell: text = "#!/bin/zsh\n\n"
        }
        return Data(text.utf8)
    }
}

/// 用户模板：模板文件夹里的一个文件（或文件夹）。
struct UserTemplate: Identifiable, Hashable {
    var url: URL
    var name: String { url.lastPathComponent }
    var id: String { url.path }
}

enum FileTemplateLogic {
    /// 名字里的 {日期} / {date} 换成今天（2026-10-28）。
    static func expand(_ name: String, date: Date = Date()) -> String {
        guard name.contains("{") else { return name }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: date)
        return name
            .replacingOccurrences(of: "{日期}", with: today)
            .replacingOccurrences(of: "{date}", with: today, options: .caseInsensitive)
    }

    /// 「未命名.txt」已经有了 →「未命名 2.txt」→「未命名 3.txt」（扩展名留在最后，和访达一样）。
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// 模板文件夹里放的东西都算模板：跳过隐藏文件（.DS_Store、._xxx）和 Icon\r，按名字排。
    static func visibleTemplates(_ names: [String]) -> [String] {
        names.filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 列出模板文件夹（不存在时为空）。
    static func listTemplates(in folder: URL, fileManager: FileManager = .default) -> [UserTemplate] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return visibleTemplates(names).map { UserTemplate(url: folder.appendingPathComponent($0)) }
    }

    /// 「上一次用的模板」存成一个字符串：内置是「builtin:md」，用户模板是「user:周报模板.docx」。
    static func key(builtIn: BuiltInTemplate) -> String { "builtin:" + builtIn.rawValue }
    static func key(user name: String) -> String { "user:" + name }

    enum Choice: Equatable {
        case builtIn(BuiltInTemplate)
        case user(String)
    }

    /// 读回上一次用的模板；读不懂（或那个用户模板已经删了）时用纯文本。
    static func choice(forKey key: String?, userNames: [String]) -> Choice {
        guard let key else { return .builtIn(.text) }
        if key.hasPrefix("builtin:"), let template = BuiltInTemplate(rawValue: String(key.dropFirst(8))) {
            return .builtIn(template)
        }
        if key.hasPrefix("user:") {
            let name = String(key.dropFirst(5))
            if userNames.contains(name) { return .user(name) }
        }
        return .builtIn(.text)
    }
}
