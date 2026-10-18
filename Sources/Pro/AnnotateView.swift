import AppKit
import SwiftUI

// MARK: - 图片工具 · 标注页

struct AnnotatePanel: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        if studio.items.isEmpty {
            ImageStudioDropZone()
        } else if let item = studio.items.first(where: { $0.id == studio.selection }) ?? studio.items.first {
            HStack(spacing: 0) {
                AnnotateCanvas(item: item, editor: studio.marker)
                Divider()
                AnnotateInspector(item: item, editor: studio.marker)
                    .frame(width: 280)
            }
        }
    }
}

// MARK: 画布

struct AnnotateCanvas: View {
    let item: ImageStudio.Item
    @ObservedObject var editor: MarkEditor
    @EnvironmentObject private var studio: ImageStudio

    private enum DragState {
        case idle
        case drawing(Mark, before: [Mark])
        case moving(Mark, before: [Mark])
    }

    @State private var drag: DragState?
    /// 裁剪：拖动开始时的框，以及是在画新框、移动旧框还是拖手柄缩放。
    private struct CropDrag {
        enum Mode: Equatable { case new, move, resize(AnnotateLogic.CropHandle) }
        var original: CGRect?
        var mode: Mode
    }
    @State private var cropDrag: CropDrag?
    /// 点过画布后焦点在画布上：⌫ 删的是选中的标注，不会被左边的图片列表接走。
    @FocusState private var canvasFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(item.originalSize, in: CGSize(width: geo.size.width - 48, height: geo.size.height - 48))
            let scale = fit.width / max(item.originalSize.width, 1)
            let marks = editor.list(item.id)
            let strengths = Set(marks.filter { $0.kind == .mosaic && $0.mosaic != .solid }.map(\.strength))
            let layers: [Double: MosaicLayer] = strengths.isEmpty ? [:] : editor.previewLayers(for: item, strengths: strengths)
            let renderer = MarkRenderer(base: item.preview, imageSize: item.originalSize, layers: layers)
            ZStack(alignment: .topLeading) {
                CheckerboardBackground()
                Canvas { context, _ in
                    context.withCGContext { cg in renderer.draw(marks, in: cg, scale: scale) }
                }
                if let crop = editor.crops[item.id], crop.width * scale >= 1, crop.height * scale >= 1 {
                    let r = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: fit))
                        p.addRect(r)
                    }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Path { p in
                        for i in 1...2 {
                            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(editor.tool == .crop ? 0.45 : 0), lineWidth: 0.5)
                    .allowsHitTesting(false)
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    if editor.tool == .crop {
                        // 四角、四边的缩放手柄。
                        ForEach(AnnotateLogic.CropHandle.allCases, id: \.self) { handle in
                            let c = AnnotateLogic.handlePoint(handle, of: r)
                            let side: CGFloat = handle.isCorner ? 9 : 7
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                                .frame(width: side, height: side)
                                .shadow(color: .black.opacity(0.3), radius: 1.5)
                                .offset(x: c.x - side / 2, y: c.y - side / 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
                if let selected = marks.first(where: { $0.id == editor.selected }) {
                    let b = selected.bounds
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: max(b.width * scale, 6) + 10, height: max(b.height * scale, 6) + 10)
                        .offset(x: b.minX * scale - 5, y: b.minY * scale - 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: fit.width, height: fit.height)
            .clipShape(Rectangle())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .contentShape(Rectangle())
            .gesture(gesture(scale: scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onDeleteCommand { editor.deleteSelected(item.id) }
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return CGSize(width: 1, height: 1) }
        let s = min(box.width / size.width, box.height / size.height, 4)
        return CGSize(width: max(1, size.width * s), height: max(1, size.height * s))
    }

    private func gesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !canvasFocused { canvasFocused = true }
                let start = point(value.startLocation, scale)
                let p = point(value.location, scale)
                if editor.tool == .crop {
                    cropChanged(start: start, to: p, scale: scale)
                    return
                }
                if drag == nil { begin(at: start, scale: scale) }
                update(start: start, to: p)
            }
            .onEnded { value in
                if editor.tool == .crop {
                    cropEnded(start: point(value.startLocation, scale), at: point(value.location, scale), scale: scale)
                    return
                }
                finish(start: point(value.startLocation, scale), at: point(value.location, scale), scale: scale)
                drag = nil
            }
    }

    private func cropChanged(start: CGPoint, to p: CGPoint, scale: CGFloat) {
        let size = item.originalSize
        if cropDrag == nil {
            let current = editor.crops[item.id]
            var mode = CropDrag.Mode.new
            if let current {
                if let handle = AnnotateLogic.cropHandle(at: start, of: current, tolerance: 7 / max(scale, 0.01)) {
                    mode = .resize(handle)
                } else if current.contains(start) {
                    mode = .move
                }
            }
            cropDrag = CropDrag(original: current, mode: mode)
        }
        guard let cropDrag else { return }
        let tiny = 4 / max(scale, 0.01)
        switch cropDrag.mode {
        case .move:
            guard let original = cropDrag.original else { return }
            editor.setCropLive(item.id, AnnotateLogic.clamp(original.offsetBy(dx: p.x - start.x, dy: p.y - start.y), in: size))
        case .resize(let handle):
            guard let original = cropDrag.original else { return }
            editor.setCropLive(item.id, AnnotateLogic.resizeCrop(original, handle: handle, to: p, ratio: editor.cropRatio.value,
                                                                 in: size, minSide: tiny * 2))
        case .new:
            // 刚按下、还没拖出像样的框时先保留原来的框（不然遮罩会铺满整张图，闪一下黑）。
            let r = AnnotateLogic.cropRect(from: start, to: p, ratio: editor.cropRatio.value, in: size)
            editor.setCropLive(item.id, r.width >= tiny && r.height >= tiny ? r : cropDrag.original)
        }
    }

    private func cropEnded(start: CGPoint, at p: CGPoint, scale: CGFloat) {
        defer { cropDrag = nil }
        guard let cropDrag else { return }
        let tiny = 8 / max(scale, 0.01)
        var result = editor.crops[item.id]
        if cropDrag.mode == .new, let r = result, r.width < tiny || r.height < tiny {
            // 单击（没拖出框）：保留原来的框。
            result = cropDrag.original
        }
        editor.commitCrop(item.id, result, from: cropDrag.original)
    }

    private func point(_ p: CGPoint, _ scale: CGFloat) -> CGPoint {
        let x = min(max(p.x / scale, 0), item.originalSize.width)
        let y = min(max(p.y / scale, 0), item.originalSize.height)
        return CGPoint(x: x, y: y)
    }

    private var shift: Bool { NSEvent.modifierFlags.contains(.shift) }

    private func kind(for tool: MarkTool) -> Mark.Kind? {
        switch tool {
        case .select: return nil
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .pen: return .pen
        case .text: return .text
        case .step: return .step
        case .emoji: return .emoji
        case .mosaic: return .mosaic
        case .crop: return nil
        }
    }

    private func begin(at start: CGPoint, scale: CGFloat) {
        let list = editor.list(item.id)
        let tolerance = 6 / max(scale, 0.01)
        if editor.tool != .pen, let hit = AnnotateLogic.topHit(list, at: start, tolerance: tolerance),
           let mark = list.first(where: { $0.id == hit }) {
            editor.selected = hit
            editor.adopt(mark)
            drag = .moving(mark, before: list)
            return
        }
        guard let kind = kind(for: editor.tool) else {
            editor.selected = nil
            drag = .idle
            return
        }
        var mark = Mark(kind: kind)
        mark.color = editor.color
        mark.width = editor.width(for: kind, imageSize: item.originalSize)
        mark.filled = kind == .text || kind == .rect || kind == .ellipse ? editor.filled : false
        mark.mosaic = editor.mosaicStyle
        mark.strength = MarkEditor.quantized(editor.mosaicStrength)
        if kind == .emoji { mark.text = editor.emoji }
        mark.start = start
        mark.end = start
        mark.points = [start]
        mark.rect = CGRect(origin: start, size: .zero)
        editor.selected = nil
        drag = .drawing(mark, before: list)
    }

    private func update(start: CGPoint, to p: CGPoint) {
        guard let drag else { return }
        switch drag {
        case .idle:
            return
        case .moving(let original, let before):
            let moved = original.moved(by: CGSize(width: p.x - start.x, height: p.y - start.y))
            editor.setLive(item.id, before.map { $0.id == original.id ? moved : $0 })
        case .drawing(var mark, let before):
            switch mark.kind {
            case .rect, .ellipse, .mosaic:
                mark.rect = AnnotateLogic.rect(from: start, to: p, square: shift && mark.kind != .mosaic)
            case .arrow:
                mark.end = shift ? AnnotateLogic.snapped(p, from: start) : p
            case .pen:
                if let last = mark.points.last, hypot(last.x - p.x, last.y - p.y) >= mark.width * 0.4 {
                    mark.points.append(p)
                }
            case .emoji:
                // 拖动：从起点拉出正方形；单击则在 finish 里按默认大小放。
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                mark.rect = CGRect(x: start.x - side, y: start.y - side, width: side * 2, height: side * 2)
            case .text, .step:
                return
            }
            self.drag = .drawing(mark, before: before)
            editor.setLive(item.id, before + [mark])
        }
    }

    private func finish(start: CGPoint, at p: CGPoint, scale: CGFloat) {
        guard let drag else { return }
        let tiny = 4 / max(scale, 0.01)
        switch drag {
        case .idle:
            return
        case .moving(let original, let before):
            if hypot(p.x - start.x, p.y - start.y) < 0.5 {
                editor.setLive(item.id, before)
            } else {
                let moved = original.moved(by: CGSize(width: p.x - start.x, height: p.y - start.y))
                editor.commit(item.id, before.map { $0.id == original.id ? moved : $0 }, from: before)
            }
        case .drawing(var mark, let before):
            switch mark.kind {
            case .rect, .ellipse, .mosaic:
                guard mark.rect.width >= tiny, mark.rect.height >= tiny else {
                    editor.setLive(item.id, before)
                    return
                }
            case .arrow:
                guard hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) >= tiny * 2 else {
                    editor.setLive(item.id, before)
                    return
                }
            case .pen:
                break
            case .emoji:
                if mark.rect.width < tiny * 3 {
                    mark.rect = AnnotateLogic.resized(CGRect(origin: p, size: .zero), side: mark.width)
                }
            case .step:
                let d = mark.width
                mark.number = AnnotateLogic.nextStepNumber(before)
                mark.rect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            case .text:
                mark.text = String(localized: "文字")
                mark.rect.origin = p
                MarkEditor.fitText(&mark)
                mark.rect.origin.y = max(0, p.y - mark.rect.height / 2)
            }
            editor.commit(item.id, before + [mark], from: before)
            editor.selected = mark.id
            if mark.kind == .text { editor.focusTextTick += 1 }
        }
    }
}

// MARK: 右边的设置

struct AnnotateInspector: View {
    let item: ImageStudio.Item
    @ObservedObject var editor: MarkEditor
    @EnvironmentObject private var studio: ImageStudio
    @FocusState private var textFocused: Bool
    @FocusState private var emojiFocused: Bool
    @State private var customEmoji = ""

    private var selectedMark: Mark? {
        editor.list(item.id).first { $0.id == editor.selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tools
                    style
                    if let mark = selectedMark, mark.kind == .text { textField(mark) }
                    if editor.tool == .emoji || selectedMark?.kind == .emoji { emojiPicker }
                    if editor.tool == .crop || editor.crops[item.id] != nil { cropSection }
                    redaction
                    edit
                }
                .padding(16)
            }
            Divider()
            actions.padding(14)
        }
        .onChange(of: editor.focusTextTick) { textFocused = true }
        // 打字合并成一步撤销：获得焦点时记下开始的状态，失去焦点时提交。
        .onChange(of: textFocused) {
            if textFocused { editor.beginEdit(item.id) } else { editor.endEdit(item.id) }
        }
        .onDisappear { editor.endEdit(item.id) }
    }

    /// 拖滑块合并成一步撤销。
    private func editing(_ active: Bool) {
        if active { editor.beginEdit(item.id) } else { editor.endEdit(item.id) }
    }

    private var tools: some View {
        section("工具") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(MarkTool.allCases) { tool in
                    Button {
                        editor.tool = tool
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tool.symbol).font(.system(size: 15))
                            Text(tool.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(editor.tool == tool ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(editor.tool == tool ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("拖动画框、箭头、马赛克和裁剪范围，单击放文字、序号和表情；按住 ⇧ 画正方形或 45° 箭头。点中已有的标注可以拖动，按 ⌫ 删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var style: some View {
        let kind = selectedMark?.kind
        let showMosaic = editor.tool == .mosaic || kind == .mosaic
        section("样式") {
            if !(kind == .mosaic) {
                if !(kind == .emoji || (kind == nil && editor.tool == .emoji)) {
                HStack(spacing: 7) {
                    ForEach(MarkColor.palette, id: \.self) { color in
                        Button {
                            editor.color = color
                            editor.updateSelected(item.id) { if $0.kind != .mosaic { $0.color = color } }
                        } label: {
                            Circle()
                                .fill(Color(cgColor: color.cgColor))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: editor.color == color ? 2.5 : 0).padding(-3))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                }
                HStack {
                    Text(kind == .emoji || (kind == nil && editor.tool == .emoji) ? LocalizedStringKey("大小") : LocalizedStringKey("粗细 / 字号"))
                    Slider(value: $editor.strokeScale, in: 0.4...3, onEditingChanged: editing)
                        .onChange(of: editor.strokeScale) { applyWidth() }
                }
                if !(kind == .emoji || (kind == nil && editor.tool == .emoji)) {
                Toggle("填充 / 文字底色", isOn: $editor.filled)
                    .onChange(of: editor.filled) {
                        let filled = editor.filled
                        editor.updateSelected(item.id) { if [.rect, .ellipse, .text].contains($0.kind) { $0.filled = filled } }
                    }
                }
            }
            if showMosaic {
                Picker("马赛克", selection: $editor.mosaicStyle) {
                    ForEach(MosaicStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: editor.mosaicStyle) {
                    let style = editor.mosaicStyle
                    editor.updateSelected(item.id) { if $0.kind == .mosaic { $0.mosaic = style } }
                }
                if editor.mosaicStyle != .solid {
                    HStack {
                        Text("强度")
                        Slider(value: Binding(get: { editor.mosaicStrength }, set: { value in
                            editor.mosaicStrength = value
                            let strength = MarkEditor.quantized(value)
                            editor.updateSelected(item.id) { if $0.kind == .mosaic { $0.strength = strength } }
                        }), in: 0.5...3, onEditingChanged: editing)
                    }
                }
            }
        }
    }

    private func applyWidth() {
        let size = item.originalSize
        editor.updateSelected(item.id) { mark in
            guard mark.kind != .mosaic else { return }
            let w = editor.width(for: mark.kind, imageSize: size)
            if mark.kind == .emoji {
                // 盖脸的表情大小各不相同：按滑块比例缩放当前这一个。
                let side = max(4, mark.rect.width * w / max(mark.width, 1))
                mark.rect = AnnotateLogic.resized(mark.rect, side: side)
                mark.width = w
                return
            }
            if mark.kind == .step {
                let center = CGPoint(x: mark.rect.midX, y: mark.rect.midY)
                mark.rect = CGRect(x: center.x - w / 2, y: center.y - w / 2, width: w, height: w)
            }
            mark.width = w
        }
    }

    private func textField(_ mark: Mark) -> some View {
        section("文字内容") {
            TextField("输入文字", text: Binding(
                get: { mark.text },
                set: { new in editor.updateSelected(item.id) { $0.text = new } }
            ), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($textFocused)
        }
    }

    private var emojiPicker: some View {
        section("表情") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(AnnotateLogic.quickEmojis, id: \.self) { symbol in
                    Button {
                        pickEmoji(symbol)
                    } label: {
                        Text(symbol)
                            .font(.system(size: 20))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(editor.emoji == symbol ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("其他表情", text: $customEmoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($emojiFocused)
                    .onChange(of: customEmoji) {
                        if let symbol = AnnotateLogic.firstEmoji(customEmoji) { pickEmoji(symbol) }
                        if customEmoji.count > 1 { customEmoji = AnnotateLogic.firstEmoji(customEmoji) ?? "" }
                    }
                Button("全部表情…") {
                    emojiFocused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                }
            }
            HStack {
                Button {
                    editor.coverFaces(item, studio: studio)
                } label: {
                    Label("给人脸盖上表情", systemImage: "face.smiling")
                }
                .disabled(editor.redacting)
                if editor.redacting { ProgressView().controlSize(.small) }
            }
            Text("在本机识别真人的脸，每张脸盖一个表情。点中表情可以换、拖动，滑块改大小。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cropSection: some View {
        section("裁剪") {
            Picker("比例", selection: $editor.cropRatio) {
                ForEach(CropRatio.allCases) { ratio in
                    Text(ratio == .free ? String(localized: "自由") : ratio.label).tag(ratio)
                }
            }
            .onChange(of: editor.cropRatio) {
                let size = item.originalSize
                let current = editor.crops[item.id]
                let base = current ?? CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.1, dy: size.height * 0.1)
                if editor.cropRatio != .free || current != nil {
                    editor.commitCrop(item.id, AnnotateLogic.fit(base, ratio: editor.cropRatio.value, in: size), from: current)
                }
            }
            if let crop = AnnotateLogic.pixelCrop(editor.crops[item.id], in: item.originalSize) {
                HStack {
                    Text(verbatim: "\(Int(crop.width)) × \(Int(crop.height))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消裁剪") { editor.commitCrop(item.id, nil, from: editor.crops[item.id]) }
                }
            }
            Text("在图上拖出要保留的范围，拖动框可以移动，拖四角和四边可以调大小。存图和拷贝时只留框里的部分，标注照样保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickEmoji(_ symbol: String) {
        editor.emoji = symbol
        editor.updateSelected(item.id) { if $0.kind == .emoji { $0.text = symbol } }
    }

    private var redaction: some View {
        section("自动打码") {
            Text("在本机识别，不联网。认出来的地方加上马赛克，可以再拖动或删掉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(SensitiveKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { editor.redactKinds.contains(kind) },
                        set: { on in
                            if on { editor.redactKinds.insert(kind) } else { editor.redactKinds.remove(kind) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Button {
                    editor.redact(item, studio: studio)
                } label: {
                    Label("自动打码", systemImage: "eye.slash")
                }
                .disabled(editor.redacting)
                if editor.redacting { ProgressView().controlSize(.small) }
            }
        }
    }

    private var edit: some View {
        section("编辑") {
            HStack {
                Button {
                    editor.undo(item.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                // 输入框在打字时 ⌘Z 留给输入框自己撤销文字（被禁用的按钮不响应快捷键）。
                .disabled(!editor.canUndo(item.id) || textFocused || emojiFocused)
                .help("撤销")
                Button {
                    editor.redo(item.id)
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo(item.id) || textFocused || emojiFocused)
                .help("重做")
                Button("删除选中") { editor.deleteSelected(item.id) }
                    .disabled(editor.selected == nil)
                Spacer()
                Button("清空", role: .destructive) {
                    editor.clear(item.id)
                }
                .disabled(editor.list(item.id).isEmpty && editor.crops[item.id] == nil)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    Task {
                        if let url = await editor.save(item, studio: studio) {
                            studio.show(String(localized: "已保存「\(url.lastPathComponent)」，在原图旁边"))
                        }
                    }
                } label: {
                    Text("存到原图旁边").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                Button("拷贝") { editor.copy(item, studio: studio) }
            }
            Button {
                Task {
                    if let url = await editor.save(item, studio: studio) {
                        // replace 会一起清掉旧图的标注和撤销。
                        await studio.replace(item.id, with: url)
                        studio.mode = .beautify
                    }
                }
            } label: {
                Text("保存并接着美化").frame(maxWidth: .infinity)
            }
            Text("原图不会改动，标注图存成新文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(editor.saving)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
