import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 图片工具窗口：拼图 / 美化 / 标注 / 抠图（Pro）

struct ImageStudioView: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ImageStudioList()
                    .frame(width: 168)
                Divider()
                switch studio.mode {
                case .stitch:
                    StitchCanvasView()
                    Divider()
                    StitchInspector()
                        .frame(width: 290)
                case .beautify:
                    beautify
                case .annotate:
                    AnnotatePanel()
                case .cutout:
                    CutoutPanel()
                case .upscale:
                    UpscalePanel()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(alignment: .bottom) {
            if let message = studio.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.message)
        // ⌘V 粘贴图片（输入框里的粘贴不受影响）
        .onPasteCommand(of: [.image, .fileURL, .png, .tiff]) { _ in studio.paste() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $studio.mode) {
                ForEach(ImageStudio.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            ProBadge()

            Button {
                studio.chooseFiles()
            } label: {
                Label("导入", systemImage: "plus")
            }

            Spacer()

            if studio.mode == .stitch {
                Picker("", selection: $studio.settings.layout) {
                    ForEach(StitchLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                .onChange(of: studio.settings.layout) { studio.refresh() }
            }

            Spacer()

            Button(role: .destructive) {
                studio.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(studio.items.isEmpty)
            .help("清空所有图片（原图不会动）")
        }
        .padding(.leading, 82)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var beautify: some View {
        if studio.items.isEmpty {
            ImageStudioDropZone()
        } else {
            BeautifySheet(urls: studio.items.map(\.url), toShelf: studio.toShelf, embedded: true)
                .id(studio.items.map(\.url))
        }
    }
}

extension StitchLayout {
    var title: String {
        switch self {
        case .horizontal: return String(localized: "横向")
        case .vertical: return String(localized: "竖向")
        case .grid: return String(localized: "宫格")
        case .waterfall: return String(localized: "瀑布流")
        case .justified: return String(localized: "等高行")
        }
    }
}

// MARK: - 左边：图片列表（拖动排序、裁剪微调）

struct ImageStudioList: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $studio.selection) {
                ForEach(Array(studio.items.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index)
                        .tag(item.id)
                        .contextMenu {
                            Button("移除") { studio.remove(item.id) }
                            if item.cropStart > 0 || item.cropEnd > 0 {
                                Button("取消裁剪") { studio.setCrop(item.id, start: 0, end: 0) }
                            }
                        }
                }
                .onMove { studio.move(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let id = studio.selection { studio.remove(id) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                studio.add(urls)
                return true
            }

            if studio.mode == .stitch, studio.settings.layout.isStrip, let item = selectedItem {
                cropControls(item)
            }
            Text(studio.items.isEmpty ? String(localized: "拖进图片或文件夹") : String(localized: "\(studio.items.count) 张 · 拖动调整顺序"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var selectedItem: ImageStudio.Item? {
        studio.items.first { $0.id == studio.selection }
    }

    private func row(_ item: ImageStudio.Item, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(4)
            }
            Text(item.url.lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func cropControls(_ item: ImageStudio.Item) -> some View {
        let vertical = studio.settings.layout == .vertical
        let length = vertical ? item.originalSize.height : item.originalSize.width
        let maxCrop = max(length * 0.9, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("这张的裁剪").font(.caption.weight(.semibold))
            cropSlider(vertical ? String(localized: "上方") : String(localized: "左侧"), value: item.cropStart, max: maxCrop) {
                studio.setCrop(item.id, start: $0)
            }
            cropSlider(vertical ? String(localized: "下方") : String(localized: "右侧"), value: item.cropEnd, max: maxCrop) {
                studio.setCrop(item.id, end: $0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private func cropSlider(_ title: String, value: CGFloat, max: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).frame(width: 30, alignment: .leading)
            Slider(value: Binding(get: { Double(min(value, max)) }, set: { set(CGFloat($0).rounded()) }), in: 0...Double(max))
                .controlSize(.mini)
            Text("\(Int(value))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - 中间：预览 / 空白时的拖放区

struct ImageStudioDropZone: View {
    @EnvironmentObject private var studio: ImageStudio
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("把图片拖到这里").font(.title3.weight(.semibold))
            Text("也可以选择图片，或者 ⌘V 粘贴剪贴板里的截图").foregroundStyle(.secondary)
            HStack {
                Button("选择图片…") { studio.chooseFiles() }
                    .buttonStyle(.borderedProminent)
                Button("从剪贴板粘贴") { studio.paste() }
            }
            Text("PNG · JPG · HEIC · WebP · TIFF · BMP").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(18)
        )
        .dropDestination(for: URL.self) { urls, _ in
            studio.add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct StitchCanvasView: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        if studio.items.isEmpty {
            ImageStudioDropZone()
        } else {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let preview = studio.preview {
                        let size = fitted(preview.size, in: geo.size)
                        Image(nsImage: preview)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .background(CheckerboardBackground())
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                            .padding(24)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    } else {
                        ProgressView().frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .background(Color.primary.opacity(0.04))
            .dropDestination(for: URL.self) { urls, _ in
                studio.add(urls)
                return true
            }
        }
    }

    /// 一般整张放进窗口；特别长的竖图 / 横图按宽 / 高铺满，滚动查看。
    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        let area = CGSize(width: max(box.width - 48, 50), height: max(box.height - 48, 50))
        guard size.width > 0, size.height > 0 else { return area }
        let fit = min(area.width / size.width, area.height / size.height)
        let tall = size.height / size.width > (area.height / area.width) * 2.2
        let wide = size.width / size.height > (area.width / area.height) * 2.2
        var scale = fit
        if tall { scale = min(area.width / size.width, 1.5) }
        if wide { scale = min(area.height / size.height, 1.5) }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell + 1) {
                for col in 0..<Int(size.width / cell + 1) where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

// MARK: - 右边：拼图设置

struct StitchInspector: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if studio.settings.layout.isStrip {
                        section("拼接") {
                            Button {
                                studio.autoStitch()
                            } label: {
                                Label("自动拼接", systemImage: "wand.and.stars")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(studio.items.count < 2 || studio.working)
                            Text("找出相邻截图重叠的部分，只保留一份；选中左边的图可以微调裁剪")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("自动去除重复的顶栏、底栏", isOn: setting(\.removeBars))
                            if studio.items.contains(where: { $0.cropStart > 0 || $0.cropEnd > 0 }) {
                                Button("取消全部裁剪") { studio.resetCrops() }
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        section("排版") {
                            slider("列数", value: Binding(get: { Double(studio.settings.columns) },
                                                         set: { update(\.columns, Int($0.rounded())) }),
                                   range: 1...8, step: 1, text: "\(studio.settings.columns)")
                            if studio.settings.layout == .waterfall {
                                Toggle("按顺序填列（不找最短的一列）", isOn: setting(\.fillInOrder))
                            }
                        }
                    }

                    section("画面") {
                        slider("间距", value: setting(\.gap), range: 0...120, text: "\(Int(studio.settings.gap))")
                        if studio.settings.separateInsets {
                            slider("上边距", value: inset(\.top), range: 0...300, text: "\(Int(studio.settings.insets.top))")
                            slider("下边距", value: inset(\.bottom), range: 0...300, text: "\(Int(studio.settings.insets.bottom))")
                            slider("左边距", value: inset(\.left), range: 0...300, text: "\(Int(studio.settings.insets.left))")
                            slider("右边距", value: inset(\.right), range: 0...300, text: "\(Int(studio.settings.insets.right))")
                        } else {
                            slider("外边距", value: setting(\.margin), range: 0...300, text: "\(Int(studio.settings.margin))")
                        }
                        Toggle("四边分别设置", isOn: Binding(get: { studio.settings.separateInsets }, set: { on in
                            var s = studio.settings
                            if on, !s.separateInsets { s.insets = StitchInsets(all: CGFloat(s.margin)) }
                            s.separateInsets = on
                            studio.settings = s
                            studio.refresh()
                        }))
                        slider("图片圆角", value: setting(\.imageCorner), range: 0...120, text: "\(Int(studio.settings.imageCorner))")
                        slider("画布圆角", value: setting(\.canvasCorner), range: 0...200, text: "\(Int(studio.settings.canvasCorner))")
                        HStack {
                            Text("背景色")
                            Spacer()
                            ColorPicker("", selection: color(\.background), supportsOpacity: true).labelsHidden()
                        }
                    }

                    section("水印") {
                        Toggle("加水印", isOn: setting(\.watermarkOn))
                        if studio.settings.watermarkOn {
                            TextField("水印文字", text: Binding(get: { studio.settings.watermarkText },
                                                             set: { update(\.watermarkText, $0) }))
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                if let path = studio.settings.watermarkImage {
                                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "photo")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .font(.caption)
                                    Button {
                                        update(\.watermarkImage, nil)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button("用图片当水印…") { chooseWatermark() }
                                        .controlSize(.small)
                                }
                                Spacer()
                                ColorPicker("", selection: color(\.watermarkColor), supportsOpacity: false)
                                    .labelsHidden()
                                    .disabled(studio.settings.watermarkImage != nil)
                                    .help("文字颜色")
                            }
                            slider("字号", value: setting(\.watermarkSize), range: 12...240, text: "\(Int(studio.settings.watermarkSize))")
                            slider("透明度", value: setting(\.watermarkOpacity), range: 5...100, text: "\(Int(studio.settings.watermarkOpacity))")
                            slider("倾斜", value: setting(\.watermarkTilt), range: -90...90, text: "\(Int(studio.settings.watermarkTilt))°")
                            Toggle("平铺满整张图", isOn: setting(\.watermarkTile))
                            if studio.settings.watermarkTile {
                                Picker("密度", selection: setting(\.watermarkDensity)) {
                                    Text("稀疏").tag(0)
                                    Text("中等").tag(1)
                                    Text("密集").tag(2)
                                }
                            } else {
                                Picker("位置", selection: setting(\.watermarkAnchor)) {
                                    ForEach(StitchAnchor.allCases) { Text($0.title).tag($0) }
                                }
                            }
                        }
                    }

                    section("序号") {
                        Toggle("给每张图标上序号", isOn: setting(\.numberOn))
                        if studio.settings.numberOn {
                            Picker("位置", selection: setting(\.numberAnchor)) {
                                ForEach(StitchAnchor.corners) { Text($0.title).tag($0) }
                            }
                        }
                    }

                    section("导出") {
                        Picker("输出大小", selection: setting(\.scale)) {
                            ForEach(StitchScale.allCases) { Text($0.title).tag($0) }
                        }
                        if studio.settings.scale == .longEdge {
                            HStack {
                                Text("长边不超过")
                                TextField("", value: Binding(get: { studio.settings.longEdge },
                                                             set: { update(\.longEdge, min(max($0, 100), 30000)) }),
                                          format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                Text("像素").foregroundStyle(.secondary)
                            }
                        }
                        Picker("格式", selection: setting(\.quality)) {
                            ForEach(StitchQuality.allCases) { Text($0.title).tag($0) }
                        }
                        HStack {
                            Text("输出尺寸")
                            Spacer()
                            Text(studio.outputSize == .zero ? "—" : "\(Int(studio.outputSize.width)) × \(Int(studio.outputSize.height))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            VStack(spacing: 8) {
                Button {
                    studio.copyToClipboard()
                } label: {
                    Text("拷贝到剪贴板").frame(maxWidth: .infinity)
                }
                Button {
                    studio.export()
                } label: {
                    HStack {
                        if studio.working { ProgressView().controlSize(.small) }
                        Text("导出").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                Text("保存在第一张图旁边，原图不动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .disabled(studio.items.isEmpty || studio.working)
            .padding(14)
        }
    }

    // MARK: 小部件

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            content()
        }
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil, text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 58, alignment: .leading)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
    }

    private func update<T>(_ key: WritableKeyPath<StitchSettings, T>, _ value: T) {
        studio.settings[keyPath: key] = value
        studio.refresh()
    }

    private func setting<T>(_ key: WritableKeyPath<StitchSettings, T>) -> Binding<T> {
        Binding(get: { studio.settings[keyPath: key] }, set: { update(key, $0) })
    }

    private func inset(_ key: WritableKeyPath<StitchInsets, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(studio.settings.insets[keyPath: key]) },
                set: { studio.settings.insets[keyPath: key] = CGFloat($0); studio.refresh() })
    }

    private func color(_ key: WritableKeyPath<StitchSettings, StitchColor>) -> Binding<Color> {
        Binding(get: { studio.settings[keyPath: key].color }, set: { update(key, StitchColor($0)) })
    }

    private func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "用作水印")
        if panel.runModal() == .OK, let url = panel.url { update(\.watermarkImage, url.path) }
    }
}

// MARK: - 抠图

struct CutoutPanel: View {
    @EnvironmentObject private var studio: ImageStudio
    @State private var running = false
    @State private var results: [ImageStudio.Item.ID: URL] = [:]
    @State private var status = ""

    var body: some View {
        if studio.items.isEmpty {
            ImageStudioDropZone()
        } else if let item = studio.items.first(where: { $0.id == studio.selection }) ?? studio.items.first {
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    pane(String(localized: "原图"), image: item.thumbnail)
                    pane(String(localized: "抠好的"), image: results[item.id].flatMap { NSImage(contentsOf: $0) })
                }
                .frame(maxHeight: .infinity)
                Text(status.isEmpty ? String(localized: "在本机识别主体，去掉背景，存成透明 PNG，放在原图旁边。") : status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("抠这张") { run([item]) }
                        .buttonStyle(.borderedProminent)
                    if studio.items.count > 1 {
                        Button(String(localized: "全部抠图（\(studio.items.count) 张）")) { run(studio.items) }
                    }
                    if results[item.id] != nil {
                        Divider().frame(height: 18)
                        Button("用抠好的图接着美化") { useResults(then: .beautify) }
                        Button("用抠好的图拼图") { useResults(then: .stitch) }
                    }
                }
                .disabled(running)
            }
            .padding(22)
        }
    }

    private func pane(_ title: String, image: NSImage?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                CheckerboardBackground()
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(10)
                } else if running {
                    ProgressView()
                } else {
                    Image(systemName: "person.and.background.dotted").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func run(_ items: [ImageStudio.Item]) {
        guard MediaTools.requirePro() else { return }
        running = true
        status = String(localized: "正在抠图…")
        Task {
            var done = 0
            var missed = 0
            for item in items {
                let url = item.url
                switch await Task.detached(priority: .userInitiated, operation: { MediaTools.cutout(url) }).value {
                case .success(let result):
                    results[item.id] = result
                    done += 1
                case .noSubject, .failed:
                    missed += 1
                }
            }
            running = false
            status = missed == 0 ? String(localized: "已抠好 \(done) 张，存在原图旁边")
                                 : String(localized: "已抠好 \(done) 张，\(missed) 张没认出主体")
            if done > 0 { LibraryStore.shared?.filesChangedTick += 1 }
        }
    }

    private func useResults(then mode: ImageStudio.Mode) {
        for (id, url) in results { studio.replace(id, with: url) }
        results = [:]
        status = ""
        studio.mode = mode
    }
}
