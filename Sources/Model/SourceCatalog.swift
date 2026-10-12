import Foundation

/// 一个好认的下载来源，例如 “Gmail”“微信”“GitHub”。只依赖 Foundation，单元测试也会编译它。
struct DownloadSource: Hashable, Identifiable {
    let id: String
    let name: String
    /// SF Symbols 名称。
    let symbol: String
    /// 卡片配色，取值见 `SourceTint`。
    let tint: SourceTint
    /// 匹配的域名（后缀匹配，例如 "mail.google.com" 也匹配 "x.mail.google.com"）。
    let hosts: [String]
    /// 搜索时可以用的别名，例如 “from gmail”“来自微信”。
    let aliases: [String]
}

enum SourceTint: String, Hashable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
}

enum SourceCatalog {
    static let known: [DownloadSource] = [
        DownloadSource(id: "gmail", name: "Gmail", symbol: "envelope", tint: .red,
                       hosts: ["mail.google.com", "mail-attachment.googleusercontent.com"],
                       aliases: ["gmail", "谷歌邮箱"]),
        DownloadSource(id: "gdrive", name: String(localized: "Google 云端硬盘"), symbol: "externaldrive.badge.icloud", tint: .yellow,
                       hosts: ["drive.google.com", "docs.google.com", "drive.usercontent.google.com", "googleusercontent.com"],
                       aliases: ["google drive", "drive", "谷歌网盘", "谷歌云端硬盘"]),
        DownloadSource(id: "outlook", name: "Outlook", symbol: "envelope.badge", tint: .blue,
                       hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com", "attachments.office.net"],
                       aliases: ["outlook", "hotmail"]),
        DownloadSource(id: "qqmail", name: String(localized: "QQ 邮箱"), symbol: "envelope.open", tint: .teal,
                       hosts: ["mail.qq.com", "exmail.qq.com"],
                       aliases: ["qq邮箱", "qqmail"]),
        DownloadSource(id: "163mail", name: String(localized: "网易邮箱"), symbol: "envelope.open", tint: .red,
                       hosts: ["mail.163.com", "mail.126.com", "mail.yeah.net"],
                       aliases: ["网易邮箱", "163邮箱", "163"]),
        DownloadSource(id: "chatgpt", name: "ChatGPT", symbol: "sparkles", tint: .mint,
                       hosts: ["chatgpt.com", "chat.openai.com", "openai.com", "oaiusercontent.com"],
                       aliases: ["chatgpt", "openai", "gpt"]),
        DownloadSource(id: "claude", name: "Claude", symbol: "sparkle", tint: .orange,
                       hosts: ["claude.ai", "anthropic.com"],
                       aliases: ["claude"]),
        DownloadSource(id: "gemini", name: "Gemini", symbol: "sparkles", tint: .indigo,
                       hosts: ["gemini.google.com"],
                       aliases: ["gemini"]),
        DownloadSource(id: "wechat", name: String(localized: "微信"), symbol: "message", tint: .green,
                       hosts: ["weixin.qq.com", "wx.qq.com", "servicewechat.com", "wechat.com", "mp.weixin.qq.com"],
                       aliases: ["微信", "wechat", "weixin"]),
        DownloadSource(id: "qq", name: "QQ", symbol: "bubble.left", tint: .blue,
                       hosts: ["qq.com", "qpic.cn", "gtimg.cn"],
                       aliases: ["qq"]),
        DownloadSource(id: "feishu", name: String(localized: "飞书"), symbol: "paperplane", tint: .indigo,
                       hosts: ["feishu.cn", "larksuite.com", "larkoffice.com", "feishucdn.com"],
                       aliases: ["飞书", "feishu", "lark"]),
        DownloadSource(id: "dingtalk", name: String(localized: "钉钉"), symbol: "bell", tint: .blue,
                       hosts: ["dingtalk.com"],
                       aliases: ["钉钉", "dingtalk"]),
        DownloadSource(id: "baidupan", name: String(localized: "百度网盘"), symbol: "icloud.and.arrow.down", tint: .blue,
                       hosts: ["pan.baidu.com", "baidupcs.com", "yun.baidu.com"],
                       aliases: ["百度网盘", "百度云", "baidu pan"]),
        DownloadSource(id: "aliyunpan", name: String(localized: "阿里云盘"), symbol: "icloud.and.arrow.down", tint: .orange,
                       hosts: ["alipan.com", "aliyundrive.com", "aliyundrive.net"],
                       aliases: ["阿里云盘", "aliyun drive"]),
        DownloadSource(id: "quark", name: String(localized: "夸克网盘"), symbol: "icloud.and.arrow.down", tint: .purple,
                       hosts: ["pan.quark.cn", "quark.cn"],
                       aliases: ["夸克", "夸克网盘", "quark"]),
        DownloadSource(id: "icloud", name: "iCloud", symbol: "icloud", tint: .blue,
                       hosts: ["icloud.com", "icloud-content.com"],
                       aliases: ["icloud"]),
        DownloadSource(id: "dropbox", name: "Dropbox", symbol: "shippingbox", tint: .blue,
                       hosts: ["dropbox.com", "dropboxusercontent.com"],
                       aliases: ["dropbox"]),
        DownloadSource(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", tint: .gray,
                       hosts: ["github.com", "githubusercontent.com", "github.io", "objects.githubusercontent.com"],
                       aliases: ["github"]),
        DownloadSource(id: "slack", name: "Slack", symbol: "number", tint: .purple,
                       hosts: ["slack.com", "slack-edge.com", "slack-files.com"],
                       aliases: ["slack"]),
        DownloadSource(id: "telegram", name: "Telegram", symbol: "paperplane", tint: .teal,
                       hosts: ["telegram.org", "t.me", "web.telegram.org"],
                       aliases: ["telegram", "电报"]),
        DownloadSource(id: "whatsapp", name: "WhatsApp", symbol: "phone.bubble", tint: .green,
                       hosts: ["whatsapp.com", "whatsapp.net"],
                       aliases: ["whatsapp"]),
        DownloadSource(id: "x", name: "X", symbol: "xmark", tint: .gray,
                       hosts: ["x.com", "twitter.com", "twimg.com"],
                       aliases: ["x", "twitter", "推特"]),
        DownloadSource(id: "xiaohongshu", name: String(localized: "小红书"), symbol: "book.closed", tint: .red,
                       hosts: ["xiaohongshu.com", "xhscdn.com"],
                       aliases: ["小红书", "xiaohongshu", "rednote"]),
        DownloadSource(id: "weibo", name: String(localized: "微博"), symbol: "eye", tint: .orange,
                       hosts: ["weibo.com", "weibo.cn", "sinaimg.cn"],
                       aliases: ["微博", "weibo"]),
        DownloadSource(id: "bilibili", name: String(localized: "哔哩哔哩"), symbol: "play.tv", tint: .pink,
                       hosts: ["bilibili.com", "hdslb.com", "b23.tv"],
                       aliases: ["b站", "哔哩哔哩", "bilibili"]),
        DownloadSource(id: "youtube", name: "YouTube", symbol: "play.rectangle", tint: .red,
                       hosts: ["youtube.com", "youtu.be", "googlevideo.com"],
                       aliases: ["youtube", "油管"]),
        DownloadSource(id: "canva", name: "Canva", symbol: "paintpalette", tint: .teal,
                       hosts: ["canva.com", "canva.cn"],
                       aliases: ["canva", "可画"]),
        DownloadSource(id: "figma", name: "Figma", symbol: "pencil.and.outline", tint: .purple,
                       hosts: ["figma.com"],
                       aliases: ["figma"]),
        DownloadSource(id: "notion", name: "Notion", symbol: "doc.richtext", tint: .gray,
                       hosts: ["notion.so", "notion.site", "notion-static.com"],
                       aliases: ["notion"]),
        DownloadSource(id: "pinterest", name: "Pinterest", symbol: "pin", tint: .red,
                       hosts: ["pinterest.com", "pinimg.com"],
                       aliases: ["pinterest"]),
        DownloadSource(id: "apple", name: "Apple", symbol: "apple.logo", tint: .gray,
                       hosts: ["apple.com", "mzstatic.com"],
                       aliases: ["apple", "苹果"]),
        DownloadSource(id: "extension", name: String(localized: "浏览器扩展"), symbol: "puzzlepiece.extension", tint: .indigo,
                       hosts: [],
                       aliases: ["扩展", "插件", "extension", "extensions"]),
    ]

    private static let byID: [String: DownloadSource] = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) })

    static func source(id: String) -> DownloadSource? { byID[id] }

    /// 去掉 www. 之后的域名。
    static func host(of string: String) -> String? {
        guard let url = URL(string: string), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 根据 kMDItemWhereFroms 判断来源。认不出来时按网站域名单独成一组。
    static func classify(whereFroms: [String]) -> DownloadSource? {
        guard !whereFroms.isEmpty else { return nil }
        let lowered = whereFroms.map { $0.lowercased() }
        if lowered.contains(where: { $0.hasPrefix("chrome-extension://") || $0.hasPrefix("moz-extension://") || $0.hasPrefix("safari-web-extension://") }) {
            return byID["extension"]
        }
        let hosts = lowered.compactMap(host(of:))
        // 先看引用页（通常是第二项），再看真实下载地址。
        let ordered = hosts.count > 1 ? [hosts[1], hosts[0]] + hosts.dropFirst(2) : hosts
        for h in ordered {
            if let match = match(host: h) { return match }
        }
        if let h = ordered.first {
            return DownloadSource(id: "site:\(h)", name: h, symbol: "globe", tint: .gray, hosts: [h], aliases: [])
        }
        return DownloadSource(id: "other", name: String(localized: "其他来源"), symbol: "questionmark.folder", tint: .gray, hosts: [], aliases: [])
    }

    static func match(host: String) -> DownloadSource? {
        for source in known {
            for h in source.hosts where host == h || host.hasSuffix("." + h) {
                return source
            }
        }
        return nil
    }

    /// 搜索里写的来源（“gmail”“微信”“github.com”）对应的网址片段。
    static func searchPatterns(for term: String) -> [String] {
        let t = term.lowercased().trimmingCharacters(in: .whitespaces)
        if let source = known.first(where: { $0.aliases.contains(t) || $0.id == t || $0.name.lowercased() == t }) {
            if source.id == "extension" { return ["chrome-extension://", "moz-extension://", "safari-web-extension://"] }
            if !source.hosts.isEmpty { return source.hosts }
        }
        return [t]
    }
}
