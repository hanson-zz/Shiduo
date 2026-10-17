import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「文件夹上色」编辑器：左边实时预览，右边颜色、叠加层、大小、历史。
struct FolderIconEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = FolderIconService.shared

    /// 完成后的一句话（给主窗口弹 toast）。
    var onDone: (String) -> Void = { _ in }

    enum Kind: Hashable, CaseIterable, Identifiable {
        case off, symbol, emoji, image
        var id: Self { self }
        var title: String {
            switch self {
            case .off: return String(localized: "无")
            case .symbol: return String(localized: "符号")
            case .emoji: return String(localized: "Emoji")
            case .image: return String(localized: "图片")
            }
        }
    }

    @State private var folders: [URL]
    @State private var color: String
    @State private var kind: Kind = .off
    @State private var symbol = "star.fill"
    @State private var emoji = "📁"
    @State private var imagePath: String?
    @State private var scale = FolderIconStyle.defaultScale
    @State private var symbolQuery = ""
    @State private var preview: NSImage?
    @State private var historyImages: [FolderIconStyle: NSImage] = [:]
    @State private var dropTargeted = false
    @State private var errorText: String?

    init(urls: [URL], seedColor: String?, onDone: @escaping (String) -> Void = { _ in }) {
        self.onDone = onDone
        _folders = State(initialValue: urls)
        let saved = urls.first.flatMap { FolderIconService.shared.style(for: $0) }
        let start = saved ?? FolderIconStyle(color: seedColor ?? FolderPalette.hex(FolderPalette.colors[4].1))
        _color = State(initialValue: seedColor.flatMap(FolderIconStyle.normalizedHex) ?? start.color)
        _scale = State(initialValue: start.overlayScale)
        switch start.overlay {
        case .none: _kind = State(initialValue: .off)
        case .symbol(let name):
            _kind = State(initialValue: .symbol)
            _symbol = State(initialValue: name)
        case .emoji(let text):
            _kind = State(initialValue: .emoji)
            _emoji = State(initialValue: text)
        case .image(let path):
            _kind = State(initialValue: .image)
            _imagePath = State(initialValue: path)
        }
    }

    private var style: FolderIconStyle {
        let overlay: FolderIconStyle.Overlay
        switch kind {
        case .off: overlay = .none
        case .symbol: overlay = .symbol(symbol)
        case .emoji: overlay = emoji.isEmpty ? FolderIconStyle.Overlay.none : .emoji(emoji)
        case .image: overlay = imagePath.map { FolderIconStyle.Overlay.image($0) } ?? FolderIconStyle.Overlay.none
        }
        return FolderIconStyle(color: color, overlay: overlay, overlayScale: scale)
    }

    private var title: String {
        if folders.count == 1 { return String(localized: "给「\(folders[0].lastPathComponent)」上色") }
        return String(localized: "给 \(folders.count) 个文件夹上色")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 22) {
                previewPane
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        colorSection
                        overlaySection
                        sizeSection
                        historySection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
                }
            }
            footer
        }
        .padding(22)
        .frame(width: 720, height: 600)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { urls in addFolders(urls) }
        }
        .task(id: style) { preview = FolderIconRenderer.render(style, pixels: 512) }
        .onAppear(perform: renderHistory)
        .alert("有些文件夹没改成", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 各部分

    private var header: some View {
        HStack(spacing: 10) {
            TintedIcon(symbol: ProFeature.folderIcon.symbol, tint: ProFeature.folderIcon.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    ProBadge()
                }
                Text("把文件夹拖到这里可以一起上色")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var previewPane: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.04))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(14)
                }
            }
            .frame(width: 230, height: 230)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(folders, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if folders.count > 1 {
                                Button {
                                    folders.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("不给这个文件夹上色")
                            }
                        }
                        .font(.callout)
                        .help(url.path)
                    }
                }
            }
            .frame(width: 230)
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("颜色")
            HStack(spacing: 8) {
                ForEach(FolderPalette.colors.indices, id: \.self) { i in
                    let hex = FolderPalette.hex(FolderPalette.colors[i].1)
                    Button {
                        color = hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: FolderPalette.colors[i].1))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(color == hex ? 0.85 : 0.12), lineWidth: color == hex ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(FolderPalette.colors[i].0)
                }
                Button {
                    FolderColorPanel.shared.open(initial: FolderPalette.color(hex: color) ?? .systemBlue) { picked in
                        color = FolderPalette.hex(picked)
                    }
                } label: {
                    Image(systemName: "eyedropper")
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center).opacity(0.35)))
                }
                .buttonStyle(.plain)
                .help("自定义颜色…")
            }
        }
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("叠加")
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .off:
                EmptyView()
            case .symbol:
                symbolPicker
            case .emoji:
                HStack(spacing: 10) {
                    TextField("输入一个 emoji", text: $emoji)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: emoji) {
                            // 只留最后输入的一个字符（emoji 可能由多个码位组成，按字形算）
                            if emoji.count > 1, let last = emoji.last { emoji = String(last) }
                        }
                    Button("表情与符号…") { NSApp.orderFrontCharacterPalette(nil) }
                }
            case .image:
                HStack(spacing: 10) {
                    Button("选择图片…", action: chooseImage)
                    if let imagePath {
                        Text(URL(fileURLWithPath: imagePath).lastPathComponent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("PNG、JPG、HEIC、SVG、ICNS")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索符号（英文，如 star、music）", text: $symbolQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                    ForEach(FolderIconSymbols.matching(symbolQuery), id: \.self) { name in
                        Button {
                            symbol = name
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 15))
                                .frame(width: 34, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(symbol == name ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("叠加层大小")
            HStack {
                Slider(value: $scale, in: FolderIconStyle.scaleRange)
                Text(verbatim: "\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(kind == .off)
            Button {
                randomize()
            } label: {
                Label("随机", systemImage: "dice")
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !service.history.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("历史")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(service.history, id: \.self) { item in
                            Button {
                                load(item)
                            } label: {
                                Group {
                                    if let image = historyImages[item] {
                                        Image(nsImage: image).resizable().interpolation(.high)
                                    } else {
                                        Color.primary.opacity(0.05)
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .background(RoundedRectangle(cornerRadius: 8).fill(item == style ? Color.accentColor.opacity(0.2) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("还原默认") {
                let outcome = service.restore(folders.filter { service.hasRecord($0) })
                finish(outcome, done: String(localized: "已还原 \(outcome.succeeded.count) 个文件夹图标"))
            }
            .disabled(!folders.contains { service.hasRecord($0) })
            .help("只还原拾掇上过色的文件夹")
            Button("导出 PNG…", action: exportPNG)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("应用") {
                let outcome = service.apply(style, to: folders)
                finish(outcome, done: String(localized: "已给 \(outcome.succeeded.count) 个文件夹上色"))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(folders.isEmpty)
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.subheadline.weight(.semibold))
    }

    // MARK: 动作

    private func finish(_ outcome: FolderIconOutcome, done: String) {
        if !outcome.succeeded.isEmpty { onDone(done) }
        if outcome.failed.isEmpty {
            dismiss()
        } else {
            folders = outcome.failed.map { $0.url }
            errorText = outcome.failureText
            renderHistory()
        }
    }

    private func load(_ item: FolderIconStyle) {
        color = item.color
        scale = item.overlayScale
        switch item.overlay {
        case .none: kind = .off
        case .symbol(let name): kind = .symbol; symbol = name
        case .emoji(let text): kind = .emoji; emoji = text
        case .image(let path): kind = .image; imagePath = path
        }
    }

    private func randomize() {
        if Bool.random() {
            color = FolderPalette.hex(FolderPalette.colors.randomElement()?.1 ?? .systemBlue)
        } else {
            color = FolderPalette.hex(NSColor(hue: .random(in: 0...1), saturation: .random(in: 0.35...0.7), brightness: .random(in: 0.7...0.95), alpha: 1))
        }
        kind = .symbol
        symbol = FolderIconSymbols.all.randomElement() ?? "star.fill"
        scale = .random(in: 0.38...0.55)
    }

    private func renderHistory() {
        var images: [FolderIconStyle: NSImage] = [:]
        for item in service.history { images[item] = historyImages[item] ?? FolderIconRenderer.render(item, pixels: 96) }
        historyImages = images
    }

    private func addFolders(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { continue }
            folders.append(url)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .svg, .icns]
        panel.message = String(localized: "选一张图片盖在文件夹上")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imagePath = url.path
    }

    private func exportPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (folders.first?.lastPathComponent ?? String(localized: "文件夹")) + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = FolderIconRenderer.pngData(style), (try? data.write(to: url)) != nil else {
            errorText = String(localized: "PNG 没有导出成功")
            return
        }
        onDone(String(localized: "已导出「\(url.lastPathComponent)」"))
    }
}

/// 编辑器里列出的常用 SF Symbols（macOS 14 上不存在的会自动去掉）。
enum FolderIconSymbols {
    static let candidates: [String] = [
        // 常用
        "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "bolt.fill", "sparkles", "crown.fill", "checkmark.seal.fill",
        "exclamationmark.triangle.fill", "lock.fill", "key.fill", "pin.fill", "tag.fill", "bell.fill", "clock.fill", "calendar",
        "hourglass", "alarm.fill", "timer", "trash.fill", "archivebox.fill", "tray.full.fill", "shippingbox.fill", "gift.fill",
        // 文稿与工作
        "doc.fill", "doc.text.fill", "doc.richtext.fill", "doc.on.doc.fill", "list.bullet", "checklist", "note.text", "book.fill",
        "books.vertical.fill", "book.closed.fill", "newspaper.fill", "magazine.fill", "graduationcap.fill", "pencil", "pencil.and.ruler.fill",
        "paperclip", "folder.fill", "briefcase.fill", "case.fill", "building.2.fill", "building.columns.fill", "chart.bar.fill",
        "chart.pie.fill", "chart.line.uptrend.xyaxis", "dollarsign.circle.fill", "yensign.circle.fill", "creditcard.fill", "banknote.fill",
        "cart.fill", "bag.fill", "signature", "envelope.fill", "paperplane.fill", "tray.and.arrow.down.fill", "printer.fill",
        "person.fill", "person.2.fill", "person.3.fill", "person.crop.circle.fill", "figure.walk", "figure.run", "brain.head.profile",
        // 媒体
        "photo.fill", "photo.on.rectangle.angled", "camera.fill", "video.fill", "film.fill", "tv.fill", "play.rectangle.fill",
        "music.note", "music.note.list", "music.mic", "headphones", "mic.fill", "waveform", "speaker.wave.2.fill", "guitars.fill",
        "pianokeys", "paintbrush.fill", "paintbrush.pointed.fill", "paintpalette.fill", "scissors", "wand.and.stars", "theatermasks.fill",
        "gamecontroller.fill", "puzzlepiece.fill", "dice.fill", "die.face.5.fill",
        // 设备与开发
        "desktopcomputer", "laptopcomputer", "iphone", "ipad", "applewatch", "keyboard.fill", "display", "server.rack",
        "externaldrive.fill", "internaldrive.fill", "opticaldiscdrive.fill", "cpu.fill", "memorychip.fill", "network", "wifi",
        "antenna.radiowaves.left.and.right", "icloud.fill", "cloud.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "gearshape.2.fill", "slider.horizontal.3",
        "cube.fill", "shippingbox.circle.fill", "ladybug.fill", "ant.fill", "app.badge.fill", "square.stack.3d.up.fill",
        // 生活
        "house.fill", "bed.double.fill", "sofa.fill", "lamp.desk.fill", "lightbulb.fill", "fork.knife", "cup.and.saucer.fill",
        "wineglass.fill", "birthday.cake.fill", "carrot.fill", "takeoutbag.and.cup.and.straw.fill", "cart.badge.plus",
        "heart.text.square.fill", "cross.case.fill", "pills.fill", "stethoscope", "dumbbell.fill", "sportscourt.fill",
        "soccerball", "basketball.fill", "tennis.racket", "bicycle", "car.fill", "bus.fill", "tram.fill", "airplane",
        "sailboat.fill", "map.fill", "mappin.and.ellipse", "globe.asia.australia.fill", "globe", "location.fill", "suitcase.fill",
        "tent.fill", "beach.umbrella.fill", "camera.macro", "pawprint.fill", "dog.fill", "cat.fill", "bird.fill", "fish.fill",
        "tortoise.fill", "hare.fill", "teddybear.fill", "figure.and.child.holdinghands", "stroller.fill",
        // 自然与天气
        "leaf.fill", "tree.fill", "camera.filters", "sun.max.fill", "moon.fill", "moon.stars.fill", "cloud.sun.fill",
        "cloud.rain.fill", "snowflake", "flame.fill", "drop.fill", "bolt.heart.fill", "mountain.2.fill", "water.waves",
        "globe.americas.fill", "atom", "flask.fill", "testtube.2", "lasso.and.sparkles", "staroflife.fill",
        // 符号
        "circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill", "shield.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "questionmark.circle.fill", "info.circle.fill", "plus.circle.fill",
        "minus.circle.fill", "arrow.down.circle.fill", "arrow.up.circle.fill", "arrow.triangle.2.circlepath", "link",
        "number", "textformat", "character.book.closed.fill", "quote.bubble.fill", "bubble.left.and.bubble.right.fill",
        "message.fill", "phone.fill", "video.bubble.left.fill", "eye.fill", "hand.thumbsup.fill", "hands.clap.fill",
        "face.smiling.inverse", "rosette", "medal.fill", "trophy.fill", "target", "scope", "infinity", "recordingtape",
    ]

    /// 当前系统里真实存在的符号。
    static let all: [String] = {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }()

    static func matching(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.contains(q) }
    }
}
