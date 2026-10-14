import SwiftUI
import AppKit

/// 联系方式、推广和赞助相关的常量与动作。
enum Support {
    static let email = "694561981@qq.com"
    static let repoURL = UpdateChecker.repoURL
    static let websiteURL = URL(string: "https://shiduo.app")!
    /// 海外赞助（Ko-fi，支持银行卡 / PayPal / Apple Pay）。
    static let kofiURL = URL(string: "https://ko-fi.com/hanson528")!
    static let shareText = String(localized: "拾掇 Shiduo：免费开源的 Mac 文件管家，看图找文件、搜图里的字、清理重复和大文件。")

    static func mailURL(subject: String, body: String = "") -> URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if !body.isEmpty { c.queryItems?.append(URLQueryItem(name: "body", value: body)) }
        return c.url ?? URL(string: "mailto:\(email)")!
    }

    static let issuesURL = URL(string: "https://github.com/hanson-zz/Shiduo/issues/new")!

    static func openRepo() { NSWorkspace.shared.open(repoURL) }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var sponsorLetter: String { String(localized: """
    大家好，我是 Hanson 👋

    我喜欢给 Mac 💻 做一些小而顺手的工具。拾掇就是其中之一：基础功能完全免费、开源，除了检查更新和激活授权从不联网、不收集任何数据，只想帮你把文件找得更快、理得更清爽 🧹。

    做它用的是下班和周末的时间。我的愿望是能有更多时间把它打磨好，修更多 bug，加大家真正想要的功能 🚀，也继续做更多有用的开源小工具 🌱。

    如果拾掇帮你省了时间、腾出了空间，欢迎请我喝杯咖啡 ☕。金额不重要，每一份支持都是对我的信任和鼓励。不方便赞助也完全没关系，分享给朋友、在 GitHub 上点个星，对我同样意义重大 💖。

    谢谢你。

    此致，
    Hanson
    """) }
}

/// 设置里的「联系我们」+「推广」+「发送反馈」三块。
struct SupportSections: View {
    @Environment(\.openWindow) private var openWindow
    @State private var showFeedback = false

    var body: some View {
        Section {
            LabeledContent("官网") {
                Link("shiduo.app", destination: Support.websiteURL)
                    .contextMenu { Button("拷贝链接") { Support.copy(Support.websiteURL.absoluteString) } }
            }
            LabeledContent("GitHub") {
                Link("hanson-zz/Shiduo", destination: Support.repoURL)
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
                ShareLink(item: Support.websiteURL, message: Text(Support.shareText)) {
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
            Button("发送反馈…") { showFeedback = true }
                .buttonStyle(.link)
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackView()
        }
    }
}

/// 赞助小窗：自述 + 微信 / 支付宝收款码。
struct SponsorView: View {
    static let windowID = "sponsor"

    /// 0 微信、1 支付宝、2 Ko-fi。英文界面默认显示 Ko-fi。
    @State private var method = AppLanguage.effective == .simplifiedChinese ? 0 : 2

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
                    ShareLink(item: Support.websiteURL, message: Text(Support.shareText)) {
                        Label("分享给朋友", systemImage: "square.and.arrow.up")
                    }
                    Button { Support.openRepo() } label: {
                        Label("去 GitHub 点星", systemImage: "star")
                    }
                    Button { NSWorkspace.shared.open(Support.websiteURL) } label: {
                        Label("官方网站", systemImage: "safari")
                    }
                    .help("https://shiduo.app")
                }
                .fixedSize()
            }
            .frame(width: 370)

            VStack(spacing: 12) {
                Picker("", selection: $method) {
                    Text("微信").tag(0)
                    Text("支付宝").tag(1)
                    Text(verbatim: "Ko-fi").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                if method == 2 {
                    KofiCard()
                        .frame(width: 240, height: 340)
                } else {
                    Image(method == 0 ? "SponsorWeChat" : "SponsorAlipay")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 240, height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }

                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 700, height: 500)
    }

    private var caption: String {
        switch method {
        case 0: return String(localized: "用微信扫一扫，金额随意")
        case 1: return String(localized: "用支付宝扫一扫，金额随意")
        default: return String(localized: "银行卡、PayPal、Apple Pay 都可以，金额随意")
        }
    }
}

/// 海外赞助卡片：在浏览器里打开 Ko-fi 页面，也可以直接买 Pro。
private struct KofiCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white)
            Text("请我喝杯咖啡")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(verbatim: "ko-fi.com/hanson528")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
            Button {
                NSWorkspace.shared.open(Support.kofiURL)
            } label: {
                Label("在 Ko-fi 上支持", systemImage: "heart.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.85))
            .controlSize(.large)
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.open(LicenseConfig.buyURL)
            } label: {
                Text("或者买一份拾掇 Pro")
                    .underline()
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.36, green: 0.66, blue: 0.97), Color(red: 0.16, green: 0.45, blue: 0.85)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: - 发送反馈

/// 发送反馈：先看清楚要附带的诊断信息，写几句描述，再自己选择用邮件或 GitHub 发出去。
/// 用户点按钮之前什么都不会发送。
struct FeedbackView: View {
    static let windowID = "feedback"

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var diagnostics = ""
    @State private var includeDiagnostics = true
    @State private var loading = true
    @State private var copied = false

    /// mailto 链接里的正文上限（有些邮件 App 对太长的链接会直接打不开）。
    private let mailtoLimit = 1_800
    /// GitHub 新建 issue 链接的总长度上限。
    private let githubURLLimit = 7_000

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发送反馈")
                .font(.title2.weight(.bold))
            Text("说说遇到了什么问题或想要什么功能。下面的诊断信息能帮助更快找到原因，发送前你可以先看一遍。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("问题描述、复现步骤或建议……")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }

            Toggle("附带诊断信息", isOn: $includeDiagnostics)

            GroupBox {
                ScrollView {
                    Text(loading ? String(localized: "正在收集诊断信息…") : diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170)
            } label: {
                Text("诊断信息预览（不含授权码；路径里的主目录已替换为 ~）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(includeDiagnostics ? 1 : 0.45)

            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? String(localized: "已拷贝") : String(localized: "拷贝诊断信息")) {
                    Support.copy(fullText)
                    copied = true
                }
                .disabled(loading)
                Button("在 GitHub 提交问题") {
                    NSWorkspace.shared.open(githubURL)
                    dismiss()
                }
                .disabled(loading)
                Button("通过邮件发送") {
                    sendEmail()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            diagnostics = await Diagnostics.report()
            loading = false
        }
        .onChange(of: message) { copied = false }
        .onChange(of: includeDiagnostics) { copied = false }
    }

    private var subject: String {
        let first = message.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let short = first.count > 60 ? String(first.prefix(60)) + "…" : first
        return short.isEmpty ? String(localized: "拾掇反馈") : String(localized: "拾掇反馈：\(short)")
    }

    private var fullText: String {
        var parts: [String] = []
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        if includeDiagnostics && !diagnostics.isEmpty {
            parts.append("——\n" + diagnostics)
        }
        return parts.joined(separator: "\n\n")
    }

    private func sendEmail() {
        let body = fullText
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.recipients = [Support.email]
            service.subject = subject
            service.perform(withItems: [body])
            return
        }
        let short = body.count > mailtoLimit ? String(body.prefix(mailtoLimit)) + "\n…" : body
        NSWorkspace.shared.open(Support.mailURL(subject: subject, body: short))
    }

    private var githubURL: URL {
        var body = fullText
        while true {
            var c = URLComponents(url: Support.issuesURL, resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "title", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = c?.url, url.absoluteString.count <= githubURLLimit || body.isEmpty {
                return url
            }
            // 太长就从末尾截掉一截（日志最旧的放在前面，截掉的是最后几行）。
            let keep = max(0, Int(Double(body.count) * 0.85) - 20)
            body = keep == 0 ? "" : String(body.prefix(keep)) + "\n…"
        }
    }
}
