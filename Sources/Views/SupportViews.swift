import SwiftUI
import AppKit

/// 联系方式、推广和赞助相关的常量与动作。
enum Support {
    static let email = "694561981@qq.com"
    static let repoURL = UpdateChecker.repoURL
    static let shareText = String(localized: "拾掇 Shiduo：免费开源的 Mac 文件管家，看图找文件、搜图里的字、清理重复和大文件。")

    static func mailURL(subject: String, body: String = "") -> URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if !body.isEmpty { c.queryItems?.append(URLQueryItem(name: "body", value: body)) }
        return c.url ?? URL(string: "mailto:\(email)")!
    }

    static var feedbackURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let chip = String(localized: "Apple 芯片")
        #else
        let chip = "Intel"
        #endif
        let body = String(localized: "\n\n\n——\n拾掇 \(UpdateChecker.currentVersion) · macOS \(os) · \(chip)")
        return mailURL(subject: String(localized: "拾掇反馈"), body: body)
    }

    static func openFeedback() { NSWorkspace.shared.open(feedbackURL) }
    static func openRepo() { NSWorkspace.shared.open(repoURL) }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static let sponsorLetter = """
    大家好，我是 Hanson 👋

    我喜欢给 Mac 💻 做一些小而顺手的工具。拾掇就是其中之一：基础功能完全免费、开源，除了检查更新和激活授权从不联网、不收集任何数据，只想帮你把文件找得更快、理得更清爽 🧹。

    做它用的是下班和周末的时间。我的愿望是能有更多时间把它打磨好，修更多 bug，加大家真正想要的功能 🚀，也继续做更多有用的开源小工具 🌱。

    如果拾掇帮你省了时间、腾出了空间，欢迎请我喝杯咖啡 ☕。金额不重要，每一份支持都是对我的信任和鼓励。不方便赞助也完全没关系，分享给朋友、在 GitHub 上点个星，对我同样意义重大 💖。

    谢谢你。

    此致，
    Hanson
    """
}

/// 设置里的「联系我们」+「推广」+「发送反馈」三块。
struct SupportSections: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            LabeledContent("网站") {
                Link("GitHub · hanson-zz/Shiduo", destination: Support.repoURL)
                    .contextMenu { Button("拷贝链接") { Support.copy(Support.repoURL.absoluteString) } }
            }
            LabeledContent("邮箱") {
                Link(Support.email, destination: Support.mailURL(subject: String(localized: "关于拾掇")))
                    .contextMenu { Button("拷贝邮箱") { Support.copy(Support.email) } }
            }
        } header: {
            Text("联系我们")
        } footer: {
            Text("右键点击链接可以拷贝。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("推广") {
            HStack(spacing: 10) {
                ShareLink(item: Support.repoURL, message: Text(Support.shareText)) {
                    Label("分享给朋友", systemImage: "square.and.arrow.up.fill")
                        .frame(maxWidth: .infinity)
                }
                Button { Support.openRepo() } label: {
                    Label {
                        Text("在 GitHub 上星标")
                    } icon: {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    .frame(maxWidth: .infinity)
                }
                Button { openWindow(id: SponsorView.windowID) } label: {
                    Label {
                        Text("赞助")
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }

        Section {
            Button("发送反馈…") { Support.openFeedback() }
                .buttonStyle(.link)
        }
    }
}

/// 赞助小窗：自述 + 微信 / 支付宝收款码。
struct SponsorView: View {
    static let windowID = "sponsor"

    @State private var method = 0

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text("支持拾掇")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                ScrollView {
                    Text(Support.sponsorLetter)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    ShareLink(item: Support.repoURL, message: Text(Support.shareText)) {
                        Label("分享给朋友", systemImage: "square.and.arrow.up")
                    }
                    Button { Support.openRepo() } label: {
                        Label("去 GitHub 点星", systemImage: "star")
                    }
                }
            }
            .frame(width: 330)

            VStack(spacing: 12) {
                Picker("", selection: $method) {
                    Text("微信").tag(0)
                    Text("支付宝").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                Image(method == 0 ? "SponsorWeChat" : "SponsorAlipay")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 240, height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

                Text(method == 0 ? String(localized: "用微信扫一扫，金额随意") : String(localized: "用支付宝扫一扫，金额随意"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 660, height: 500)
    }
}
