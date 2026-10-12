import AppKit
import SwiftUI
import VisionKit

/// 空格预览图片：像“照片”App 一样直接划选图里的文字，点电话、网址、邮箱。
struct LiveTextPreview: View {
    @EnvironmentObject private var store: LibraryStore
    let item: FileItem
    let onClose: () -> Void
    let onStep: (Int) -> Void

    @State private var highlight = false
    @State private var transcript = ""
    @State private var status: LiveTextStatus = .analyzing
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                LiveTextImageView(
                    url: item.url, highlight: highlight,
                    onResult: { text, state in
                        transcript = text
                        status = state
                    }
                )
                .id(item.id)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                footer
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.space) { onClose(); return .handled }
        .onKeyPress(.leftArrow) { onStep(-1); return .handled }
        .onKeyPress(.rightArrow) { onStep(1); return .handled }
        .onChange(of: item.id) {
            highlight = false
            transcript = ""
            status = .analyzing
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.sizeText) · \(item.sortDate.shortText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                highlight.toggle()
            } label: {
                Label(highlight ? "隐藏文字框" : "显示所有文字", systemImage: "text.viewfinder")
            }
            .disabled(transcript.isEmpty)
            .help("把图里能选的文字都标出来")
            Button {
                FileActions.copy(transcript)
                store.showToast("已拷贝图中全部文字")
            } label: {
                Label("拷贝全部文字", systemImage: "doc.on.doc")
            }
            .disabled(transcript.isEmpty)
            Button {
                NSWorkspace.shared.open(item.url)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭（Esc 或空格）")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
            Text(status.text)
            Spacer()
            Text("← → 上一张 / 下一张")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

enum LiveTextStatus: Equatable {
    case analyzing
    case ready
    case noText
    case unsupported

    var text: String {
        switch self {
        case .analyzing: return "正在识别图中文字…"
        case .ready: return "可以直接用鼠标划选文字，右键拷贝；电话、网址、邮箱可以点"
        case .noText: return "这张图里没有识别到文字"
        case .unsupported: return "这台 Mac 不支持实况文本，可以用“拷贝文字”（⇧⌘C）"
        }
    }

    var symbol: String {
        switch self {
        case .analyzing: return "hourglass"
        case .ready: return "character.cursor.ibeam"
        case .noText: return "text.badge.xmark"
        case .unsupported: return "exclamationmark.triangle"
        }
    }
}

/// NSImageView + VisionKit 的 ImageAnalysisOverlayView。
struct LiveTextImageView: NSViewRepresentable {
    let url: URL
    let highlight: Bool
    let onResult: (String, LiveTextStatus) -> Void

    final class Coordinator {
        var url: URL?
        var task: Task<Void, Never>?
        let analyzer = ImageAnalyzer()
        let overlay = ImageAnalysisOverlayView()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        let overlay = context.coordinator.overlay
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .automatic
        container.addSubview(overlay)

        for view in [imageView, overlay] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        load(into: imageView, context: context)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let overlay = context.coordinator.overlay
        if overlay.selectableItemsHighlighted != highlight {
            overlay.selectableItemsHighlighted = highlight
        }
        if context.coordinator.url != url, let imageView = nsView.subviews.first as? NSImageView {
            load(into: imageView, context: context)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    private func load(into imageView: NSImageView, context: Context) {
        let coordinator = context.coordinator
        coordinator.url = url
        coordinator.task?.cancel()
        coordinator.overlay.analysis = nil
        let url = self.url
        let onResult = self.onResult
        coordinator.task = Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            guard !Task.isCancelled, let image else { return }
            imageView.image = image
            guard ImageAnalyzer.isSupported else {
                onResult("", .unsupported)
                return
            }
            do {
                let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                let analysis = try await coordinator.analyzer.analyze(image, orientation: .up, configuration: config)
                guard !Task.isCancelled else { return }
                coordinator.overlay.analysis = analysis
                let text = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                onResult(text, text.isEmpty ? .noText : .ready)
            } catch {
                if !Task.isCancelled { onResult("", .noText) }
            }
        }
    }
}
